#include "bcast_bus.h"
#include "aes_ctr.h"
#include "../net/tdma_scheduler.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <thread>

static inline uint64_t now_ns_mono() {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return uint64_t(ts.tv_sec) * 1'000'000'000ULL + uint64_t(ts.tv_nsec);
}

namespace io {

namespace {
void set_rcv_timeout(int sock, int us) {
  timeval tv{};
  tv.tv_sec = us / 1'000'000;
  tv.tv_usec = us % 1'000'000;
  setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
}
void die(const char* what) {
  std::fprintf(stderr, "BcastBus: %s: %s\n", what, std::strerror(errno));
  throw std::runtime_error(std::string("BcastBus: ") + what);
}
}  // namespace

BcastBus::BcastBus(int self_id, int nP, int port,
                   const std::vector<std::string>& ips,
                   net::TDMAScheduler* scheduler,
                   uint64_t key_seed)
    : tx_(nP), rx_(nP),
      witness_(nP * nP),
      ip_table_(nP, 0),
      self_id_(static_cast<uint8_t>(self_id)),
      nP_(nP),
      port_(port),
      scheduler_(scheduler) {
  // Populate the IP table from the supplied list. ips[p] should be
  // party p's TSN IP; we store in network byte order for fast compare
  // against src.sin_addr.s_addr in the pump.
  for (int p = 0; p < nP_ && p < (int)ips.size(); ++p) {
    in_addr a{};
    if (!ips[p].empty()
        && inet_pton(AF_INET, ips[p].c_str(), &a) == 1) {
      ip_table_[p] = a.s_addr;
    }
  }
  std::string self_tsn_ip = (self_id < (int)ips.size()) ? ips[self_id] : "";
  if (scheduler_ && scheduler_->slot_ns() > 0
      && scheduler_->cycle_slots() > 0) {
    cycle_ns_ = scheduler_->slot_ns()
              * static_cast<uint64_t>(scheduler_->cycle_slots());
  }

  sock_ = socket(AF_INET, SOCK_DGRAM, 0);
  if (sock_ < 0) die("socket");

  int one = 1;
  setsockopt(sock_, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  int bufsz = 8 * 1024 * 1024;
  setsockopt(sock_, SOL_SOCKET, SO_RCVBUF, &bufsz, sizeof(bufsz));
  setsockopt(sock_, SOL_SOCKET, SO_SNDBUF, &bufsz, sizeof(bufsz));
  setsockopt(sock_, SOL_SOCKET, SO_BROADCAST, &one, sizeof(one));
  // Tag every datagram from this socket with SO_PRIORITY=4 so the eno1
  // kernel taprio can gate MPC traffic specifically (priority 4 → tc 1 →
  // gated to owner slot) while leaving all other traffic at default
  // priority 0 (→ tc 0 → always open). SSH, NTP, etc. stay unaffected.
  // Env-var override (MPC_SO_PRIORITY=0) skips the tag for environments
  // where the qdisc isn't installed and the priority would be wasted.
  int prio = 4;
  if (const char* s = std::getenv("MPC_SO_PRIORITY")) {
    prio = static_cast<int>(std::strtol(s, nullptr, 10));
  }
  if (prio > 0) {
    if (setsockopt(sock_, SOL_SOCKET, SO_PRIORITY, &prio, sizeof(prio)) < 0) {
      // Non-fatal: kernel may need CAP_NET_ADMIN for priorities > 6.
      // We try anyway because most distros allow priority 4 unprivileged.
      std::fprintf(stderr,
                   "BcastBus[p=%u]: SO_PRIORITY=%d failed (errno=%d), "
                   "running at default priority — taprio gating may not apply\n",
                   self_id_, prio, errno);
    }
  }

  sockaddr_in local{};
  local.sin_family = AF_INET;
  local.sin_addr.s_addr = htonl(INADDR_ANY);
  local.sin_port = htons(static_cast<uint16_t>(port));
  if (bind(sock_, reinterpret_cast<sockaddr*>(&local), sizeof(local)) < 0) {
    die("bind");
  }

  bcast_addr_.sin_family = AF_INET;
  bcast_addr_.sin_port = htons(static_cast<uint16_t>(port));
  // Broadcast destination is selected by two env vars (in precedence order):
  //   1. MPC_BROADCAST_IP=<dotted-IPv4>  — explicit override (highest priority)
  //   2. MPC_NETWORK={tsn|eno1}          — semantic toggle: selects the
  //                                        appropriate broadcast address
  //                                        for the chosen interface.
  //   3. unset → default to the eno1 broadcast.
  const char* bcast_ip = std::getenv("MPC_BROADCAST_IP");
  if (!bcast_ip || !*bcast_ip) {
    const char* net = std::getenv("MPC_NETWORK");
    if (net && std::string(net) == "tsn") {
      bcast_ip = "192.168.1.255";
    } else {
      bcast_ip = "255.255.255.255";
    }
  }
  if (inet_pton(AF_INET, bcast_ip, &bcast_addr_.sin_addr) != 1) {
    die("inet_pton bcast");
  }

  self_tsn_ip_be_ = ip_table_[self_id_];

  // Derive K_{self, t} for every t. K is symmetric over the unordered
  // pair {self, t}; the nonce includes both sender_id and target_pid
  // explicitly so i->j and j->i don't collide.
  for (int t = 0; t < nP_; ++t) {
    if (t == self_id_) continue;
    io::aes_ctr::derive_pair_key(key_seed, self_id_, t, tx_[t].pair_key);
  }
}

BcastBus::~BcastBus() {
  if (pump_running_.load()) {
    pump_stop_.store(true, std::memory_order_relaxed);
    if (pump_thread_.joinable()) pump_thread_.join();
  }
  if (sock_ >= 0) close(sock_);
  std::fprintf(stderr,
               "BcastBus[p=%u]: drop_self=%lu witness_disp=%lu drop_unkn=%lu "
               "tnacks=%lu wnacks=%lu nack_origin_drop=%lu nack_recv=%lu\n",
               self_id_,
               (unsigned long)dropped_self_,
               (unsigned long)witness_dispatched_,
               (unsigned long)dropped_unknown_,
               (unsigned long)target_nacks_sent_,
               (unsigned long)witness_nacks_sent_,
               (unsigned long)nack_origin_dropped_,
               (unsigned long)nack_received_total_);
  for (int t = 0; t < nP_; ++t) {
    if (t == self_id_) continue;
    std::fprintf(stderr,
                 "  tx[%d]: app_bytes=%lu tx_dg=%lu retx=%lu evict=%lu poisoned=%d\n",
                 t,
                 (unsigned long)tx_[t].app_bytes,
                 (unsigned long)tx_[t].datagrams_tx,
                 (unsigned long)tx_[t].retx_sends,
                 (unsigned long)tx_[t].tx_buf_evictions,
                 (int)tx_[t].poisoned.load());
  }
  for (int s = 0; s < nP_; ++s) {
    if (s == self_id_) continue;
    std::fprintf(stderr,
                 "  rx[%d]: rx_dg=%lu poisoned=%d\n",
                 s,
                 (unsigned long)rx_[s].datagrams_rx,
                 (int)rx_[s].poisoned.load());
  }
}

void BcastBus::sync() {
  // 5-byte SYNC: SYNC_MAGIC (4) + self_id (1). Broadcast and wait for
  // one from every other party.
  uint8_t sync_buf[5];
  uint32_t magic = SYNC_MAGIC;
  std::memcpy(sync_buf, &magic, 4);
  sync_buf[4] = self_id_;

  std::vector<bool> seen(nP_, false);
  seen[self_id_] = true;
  int needed = nP_ - 1;
  int got = 0;

  set_rcv_timeout(sock_, 50'000);  // 50 ms

  for (int attempt = 0; attempt < 1200 && got < needed; ++attempt) {
    sendto(sock_, sync_buf, sizeof(sync_buf), 0,
           reinterpret_cast<sockaddr*>(&bcast_addr_), sizeof(bcast_addr_));
    while (true) {
      uint8_t got_buf[16];
      sockaddr_in src{};
      socklen_t slen = sizeof(src);
      ssize_t n = recvfrom(sock_, got_buf, sizeof(got_buf), 0,
                           reinterpret_cast<sockaddr*>(&src), &slen);
      if (n < 0) break;
      if (n != 5) continue;
      uint32_t got_magic;
      std::memcpy(&got_magic, got_buf, 4);
      if (got_magic != SYNC_MAGIC) continue;
      uint8_t got_id = got_buf[4];
      if (got_id == self_id_) continue;
      if (got_id < nP_ && !seen[got_id]) {
        seen[got_id] = true;
        ++got;
      }
    }
  }

  if (got < needed) {
    std::fprintf(stderr,
                 "BcastBus[p=%u]: sync TIMEOUT, saw %d of %d peers\n",
                 self_id_, got, needed);
  }

  // Trailing emits so peers that completed sync slightly later still
  // catch one of our SYNCs.
  for (int i = 0; i < 4; ++i) {
    sendto(sock_, sync_buf, sizeof(sync_buf), 0,
           reinterpret_cast<sockaddr*>(&bcast_addr_), sizeof(bcast_addr_));
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }

  // Drain any leftover sync frames.
  set_rcv_timeout(sock_, 20'000);
  while (true) {
    uint8_t tmp[16];
    ssize_t n = recvfrom(sock_, tmp, sizeof(tmp), 0, nullptr, nullptr);
    if (n <= 0) break;
  }

  // Restore default for pump's idle ticks.
  set_rcv_timeout(sock_, 100'000);
}

void BcastBus::start_pump() {
  if (pump_running_.exchange(true)) return;
  pump_thread_ = std::thread(&BcastBus::pump_loop_, this);
}

void BcastBus::send(int dst, const void* data, size_t len) {
  if (dst < 0 || dst >= nP_ || dst == self_id_) return;
  TxState& ts = tx_[dst];
  throw_if_send_poisoned_(static_cast<uint8_t>(dst));

  const auto* src = static_cast<const uint8_t*>(data);
  uint32_t seq;
  {
    std::lock_guard<std::mutex> lg(ts.mu);
    seq = ts.local_seq++;
    // Mark seq as in-flight; handle_nack_() checks this set before
    // misclassifying a NACK for a not-yet-inserted fragment as
    // "evicted" and POISONing the pipe.
    ts.streams_in_flight.insert(seq);
  }
  const uint32_t total = (len == 0)
      ? 1u
      : static_cast<uint32_t>((len + MAX_PAYLOAD - 1) / MAX_PAYLOAD);

  uint8_t buf[HEADER_SIZE + MAX_PAYLOAD];
  size_t off = 0;
  for (uint32_t i = 0; i < total; ++i) {
    uint64_t t_pre = 0;
    if (scheduler_) t_pre = scheduler_->wait_and_mark_pre();

    size_t chunk = std::min<size_t>(MAX_PAYLOAD, len - off);
    const uint32_t kind = KIND_DATA;
    const uint32_t plen = static_cast<uint32_t>(chunk);
    const uint16_t idx = static_cast<uint16_t>(i);
    const uint16_t tot16 = static_cast<uint16_t>(total);
    const uint8_t target_pid = static_cast<uint8_t>(dst);
    const uint8_t reserved6 = 0;
    const uint8_t reserved7 = 0;
    std::memcpy(buf +  0, &kind,        4);
    std::memcpy(buf +  4, &self_id_,    1);
    std::memcpy(buf +  5, &target_pid,  1);
    std::memcpy(buf +  6, &reserved6,   1);
    std::memcpy(buf +  7, &reserved7,   1);
    std::memcpy(buf +  8, &seq,         4);
    std::memcpy(buf + 12, &idx,         2);
    std::memcpy(buf + 14, &tot16,       2);
    std::memcpy(buf + 16, &plen,        4);
    if (chunk) std::memcpy(buf + HEADER_SIZE, src + off, chunk);

    if (chunk) {
      uint8_t nonce[12];
      io::aes_ctr::build_nonce(/*role=*/0, self_id_, target_pid, seq, idx,
                               nonce);
      io::aes_ctr::crypt(ts.pair_key, nonce,
                         buf + HEADER_SIZE, buf + HEADER_SIZE, chunk);
    }

    {
      std::lock_guard<std::mutex> lg(ts.mu);
      TxRecord rec;
      rec.frag_total = tot16;
      rec.payload_len = plen;
      if (chunk) rec.payload.assign(buf + HEADER_SIZE,
                                    buf + HEADER_SIZE + chunk);
      ts.tx_buf[{seq, idx}] = std::move(rec);
      if (i == 0) {
        ts.tx_buf_order.push_back(seq);
        while (ts.tx_buf_order.size() > TX_BUF_CAP_STREAMS) {
          uint32_t old = ts.tx_buf_order.front();
          ts.tx_buf_order.pop_front();
          auto lo = ts.tx_buf.lower_bound({old, 0});
          auto hi = ts.tx_buf.upper_bound({old, UINT16_MAX});
          ts.tx_buf.erase(lo, hi);
          ++ts.tx_buf_evictions;
        }
      }
    }

    ssize_t n = sendto(sock_, buf, HEADER_SIZE + chunk, 0,
                       reinterpret_cast<sockaddr*>(&bcast_addr_),
                       sizeof(bcast_addr_));
    if (n < 0) {
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        std::this_thread::sleep_for(std::chrono::microseconds(10));
        --i; continue;
      }
      die("sendto");
    }
    if (scheduler_) scheduler_->mark_post(t_pre);
    {
      std::lock_guard<std::mutex> lg(ts.mu);
      ++ts.datagrams_tx;
    }
    off += chunk;
    if (len == 0) break;
  }
  {
    std::lock_guard<std::mutex> lg(ts.mu);
    ts.app_bytes += len;
    ts.streams_in_flight.erase(seq);
  }
}

void BcastBus::recv(int src, void* data, size_t len) {
  if (src < 0 || src >= nP_ || src == self_id_) return;
  RxState& rs = rx_[src];
  throw_if_recv_poisoned_(static_cast<uint8_t>(src));

  auto* dst = static_cast<uint8_t*>(data);
  size_t remaining = len;

  std::unique_lock<std::mutex> lk(rs.mu);
  rs.cv.wait(lk, [&] {
    return rs.rx_bytes >= remaining
        || rs.poisoned.load(std::memory_order_relaxed);
  });
  if (rs.poisoned.load(std::memory_order_relaxed)) {
    lk.unlock();
    throw_if_recv_poisoned_(static_cast<uint8_t>(src));
  }
  while (remaining > 0) {
    Chunk& front = rs.rx.front();
    size_t avail = front.bytes.size() - front.offset;
    size_t take = (remaining < avail) ? remaining : avail;
    std::memcpy(dst + (len - remaining),
                front.bytes.data() + front.offset, take);
    front.offset += take;
    remaining -= take;
    rs.rx_bytes -= take;
    if (front.offset == front.bytes.size()) rs.rx.pop_front();
  }
}

int64_t BcastBus::app_bytes_sent() const {
  int64_t total = 0;
  for (const auto& t : tx_) total += static_cast<int64_t>(t.app_bytes);
  return total;
}

void BcastBus::reset_stats() {
  for (auto& t : tx_) t.app_bytes = 0;
}

uint64_t BcastBus::bytes_sent_to(int target) const {
  if (target < 0 || target >= nP_ || target == self_id_) return 0;
  return tx_[target].app_bytes;
}

void BcastBus::pump_loop_() {
  // Drain on rcvbuf-empty (EAGAIN), same as Stage B. The original
  // intent was a slot-aligned drain (per spec §C.3) firing every
  // cycle_ns, but in practice that races with the kernel rcvbuf:
  // the drain detects "gaps" for frames that are still in rcvbuf
  // waiting to be dequeued by the pump, generating storm-volume
  // false-positive NACKs that exhaust retx_k_recv and POISON the
  // pipe. Drain-on-EAGAIN avoids the race because by definition the
  // pump has caught up to rcvbuf when drain runs. Slot-aligned drain
  // remains an open improvement (spec §C.3) — would need a NACK
  // back-off > cycle_ns and/or rcvbuf-empty gating before it can
  // ship without breaking under transient kernel-queueing delays.
  set_rcv_timeout(sock_, 100'000);  // 100 ms
  uint8_t buf[HEADER_SIZE + MAX_PAYLOAD + 64];
  while (!pump_stop_.load(std::memory_order_relaxed)) {
    sockaddr_in src{};
    socklen_t slen = sizeof(src);
    ssize_t n = recvfrom(sock_, buf, sizeof(buf), 0,
                         reinterpret_cast<sockaddr*>(&src), &slen);
    if (n < 0) {
      if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
        // Drain target NACKs and witness NACKs.
        for (int s = 0; s < nP_; ++s) {
          if (s == self_id_) continue;
          drain_nack_state_(static_cast<uint8_t>(s));
          for (int t = 0; t < nP_; ++t) {
            if (t == self_id_ || t == s) continue;
            witness_drain_(static_cast<uint8_t>(s), static_cast<uint8_t>(t));
          }
        }
        continue;
      }
      std::fprintf(stderr,
                   "BcastBus: pump recvfrom errno=%d\n", errno);
      break;
    }
    if (n == 0) continue;

    if (self_tsn_ip_be_ != 0
        && src.sin_addr.s_addr == self_tsn_ip_be_) {
      ++dropped_self_;
      continue;
    }

    if (n < static_cast<ssize_t>(HEADER_SIZE)) continue;
    uint32_t kind;
    std::memcpy(&kind, buf, 4);

    if (kind == KIND_DATA)        handle_data_(buf, n);
    else if (kind == KIND_NACK)   handle_nack_(buf, n, src);
    else if (kind == KIND_POISON) handle_poison_(buf, n);
    // KIND_SYNC and unknown kinds: drop.
  }
}

void BcastBus::handle_data_(uint8_t* buf, ssize_t n) {
  uint8_t hdr_sender = buf[4];
  uint8_t hdr_target = buf[5];
  if (hdr_sender == self_id_ || hdr_sender >= nP_ || hdr_target >= nP_) {
    ++dropped_unknown_;
    return;
  }
  uint32_t seq, payload_len;
  uint16_t idx, total;
  std::memcpy(&seq,         buf +  8, 4);
  std::memcpy(&idx,         buf + 12, 2);
  std::memcpy(&total,       buf + 14, 2);
  std::memcpy(&payload_len, buf + 16, 4);
  if (n != static_cast<ssize_t>(HEADER_SIZE + payload_len)) {
    ++dropped_unknown_;
    return;
  }

  if (hdr_target != self_id_) {
    // Witness role (Stage C): track that we observed this seq from
    // hdr_sender on the (hdr_sender → hdr_target) stream. We don't
    // decrypt or reassemble; the gap detector emits a one-shot NACK
    // for any seq we miss.
    witness_observe_(hdr_sender, hdr_target, seq);
    ++witness_dispatched_;
    return;
  }

  if (payload_len > 0) {
    uint8_t nonce[12];
    io::aes_ctr::build_nonce(/*role=*/0, hdr_sender, self_id_, seq, idx,
                             nonce);
    io::aes_ctr::crypt(tx_[hdr_sender].pair_key, nonce,
                       buf + HEADER_SIZE, buf + HEADER_SIZE, payload_len);
  }

  RxState& rs = rx_[hdr_sender];
  std::lock_guard<std::mutex> lg(rs.mu);
  ++rs.datagrams_rx;
  if (!rs.any_seen || seq > rs.max_seen_seq) {
    rs.max_seen_seq = seq;
    rs.any_seen = true;
  }
  rs.nack_state.erase({seq, idx});
  if (seq < rs.next_rx_seq) return;  // late dup

  if (total == 1 && seq == rs.next_rx_seq) {
    if (payload_len > 0) {
      Chunk c;
      c.bytes.assign(buf + HEADER_SIZE,
                     buf + HEADER_SIZE + payload_len);
      rs.rx_bytes += payload_len;
      rs.rx.push_back(std::move(c));
    }
    rs.next_rx_seq++;
    drain_pending_locked_(rs);
  } else {
    auto& p = rs.pending[seq];
    if (p.frag_total == 0) {
      p.frag_total = total;
      p.frags.resize(total);
    }
    if (idx < p.frag_total) {
      if (p.frags[idx].empty()) {
        if (payload_len > 0) {
          p.frags[idx].assign(buf + HEADER_SIZE,
                              buf + HEADER_SIZE + payload_len);
        }
        p.received++;
      }
    }
    drain_pending_locked_(rs);
  }
  rs.cv.notify_all();
}

void BcastBus::drain_pending_locked_(RxState& rs) {
  while (true) {
    auto it = rs.pending.find(rs.next_rx_seq);
    if (it == rs.pending.end()) break;
    if (it->second.received != it->second.frag_total) break;
    size_t total_bytes = 0;
    for (const auto& f : it->second.frags) total_bytes += f.size();
    if (total_bytes > 0) {
      Chunk c;
      c.bytes.reserve(total_bytes);
      for (auto& f : it->second.frags) {
        c.bytes.insert(c.bytes.end(), f.begin(), f.end());
      }
      rs.rx_bytes += total_bytes;
      rs.rx.push_back(std::move(c));
    }
    rs.pending.erase(it);
    rs.next_rx_seq++;
  }
}

void BcastBus::handle_nack_(uint8_t* buf, ssize_t n,
                            const sockaddr_in& src) {
  // NACK frame layout (Stage C):
  //   header (20 B): kind=NACK, hdr_sender=NACK origin (whoever emit-
  //                  ted on the wire), hdr_target=missing_sender (the
  //                  party we're asking to retransmit).
  //   body   (12 B): missing_sender_id, missing_target_id, reserved,
  //                  missing_seq (uint32 LE), missing_idx (uint16 LE),
  //                  reserved.
  ++nack_received_total_;
  if (n < static_cast<ssize_t>(HEADER_SIZE + 12)) return;

  uint8_t hdr_target_field = buf[5];   // missing sender = whoever needs to retx
  if (hdr_target_field != self_id_) return;  // not our stream

  uint8_t missing_sender = buf[HEADER_SIZE + 0];
  uint8_t missing_target = buf[HEADER_SIZE + 1];
  uint32_t missing_seq;
  uint16_t missing_idx;
  std::memcpy(&missing_seq, buf + HEADER_SIZE + 4, 4);
  std::memcpy(&missing_idx, buf + HEADER_SIZE + 8, 2);

  if (missing_sender != self_id_) return;     // sanity
  if (missing_target >= nP_ || missing_target == self_id_) return;

  // ORIGIN CHECK (Stage C, §3 step 3 of spec): the sender retransmits
  // only on NACKs whose source IP matches the intended target's IP.
  // Witness NACKs from third parties fail this check and are dropped
  // here — they're observability/diagnostics on the wire only.
  if (src.sin_addr.s_addr != ip_table_[missing_target]) {
    ++nack_origin_dropped_;
    return;
  }

  TxState& ts = tx_[missing_target];
  if (ts.poisoned.load(std::memory_order_relaxed)) return;

  TxRecord rec_copy;
  bool found = false;
  bool over_cap = false;
  bool not_yet = false;
  {
    std::lock_guard<std::mutex> lg(ts.mu);
    auto it = ts.tx_buf.find({missing_seq, missing_idx});
    if (it != ts.tx_buf.end()) {
      ++it->second.nack_count;
      if (it->second.nack_count > retx_k_send_) {
        over_cap = true;
      } else {
        rec_copy = it->second;
        found = true;
      }
    } else {
      // The fragment isn't in tx_buf. Three reasons:
      //   (a) we haven't called send_data with this seq yet (probe /
      //       NACK race at stream start) — silent no-op.
      //   (b) send_data for this seq is currently in progress and
      //       hasn't inserted this idx into tx_buf yet — silent no-op.
      //   (c) the entry was evicted by the FIFO cap — POISON.
      not_yet = (missing_seq >= ts.local_seq) ||
                ts.streams_in_flight.count(missing_seq) > 0;
    }
  }
  if (over_cap) {
    char r[128];
    std::snprintf(r, sizeof(r),
                  "peer %u exceeded retx budget on (s=%u, i=%u)",
                  missing_target, missing_seq, (unsigned)missing_idx);
    send_poison_to_target_(missing_target, r);
    return;
  }
  if (!found) {
    if (not_yet) return;  // probe / start-of-stream race
    char r[128];
    std::snprintf(r, sizeof(r),
                  "NACK for evicted (peer=%u, s=%u, i=%u)",
                  missing_target, missing_seq, (unsigned)missing_idx);
    send_poison_to_target_(missing_target, r);
    return;
  }
  resend_fragment_(missing_target, missing_seq, missing_idx, rec_copy);
}

void BcastBus::handle_poison_(uint8_t* buf, ssize_t n) {
  uint8_t hdr_sender = buf[4];
  uint8_t hdr_target = buf[5];
  if (hdr_target != self_id_) return;
  if (hdr_sender >= nP_ || hdr_sender == self_id_) return;
  uint32_t plen;
  std::memcpy(&plen, buf + 16, 4);
  if (plen > MAX_PAYLOAD) plen = 0;
  if (n < static_cast<ssize_t>(HEADER_SIZE + plen)) return;
  std::string reason(reinterpret_cast<const char*>(buf + HEADER_SIZE),
                     plen);
  mark_recv_poisoned_(hdr_sender, "peer POISON: " + reason);
}

void BcastBus::compute_missing_locked_(RxState& rs) {
  if (!rs.any_seen) return;
  const uint64_t now = now_ns_mono();
  for (uint32_t s = rs.next_rx_seq; s <= rs.max_seen_seq; ++s) {
    auto pit = rs.pending.find(s);
    if (pit == rs.pending.end()) {
      auto [it, inserted] = rs.nack_state.try_emplace(
          std::make_pair(s, uint16_t{0}));
      if (inserted) it->second.last_nack_ns = now;
    } else {
      const Partial& part = pit->second;
      if (part.frag_total == 0) continue;
      for (uint16_t i = 0; i < part.frag_total; ++i) {
        if (part.frags[i].empty()) {
          auto [it, inserted] = rs.nack_state.try_emplace(
              std::make_pair(s, i));
          if (inserted) it->second.last_nack_ns = now;
        }
      }
    }
  }
}

void BcastBus::drain_nack_state_(uint8_t sender) {
  RxState& rs = rx_[sender];
  if (rs.poisoned.load(std::memory_order_relaxed)) return;
  std::vector<std::pair<uint32_t, uint16_t>> due;
  std::string poison_reason;
  {
    std::lock_guard<std::mutex> lg(rs.mu);
    compute_missing_locked_(rs);
    const uint64_t now = now_ns_mono();
    for (auto it = rs.nack_state.begin(); it != rs.nack_state.end(); ) {
      const uint32_t s = it->first.first;
      const uint16_t i = it->first.second;
      bool satisfied = (s < rs.next_rx_seq);
      if (!satisfied) {
        auto pit = rs.pending.find(s);
        if (pit != rs.pending.end()
            && pit->second.frag_total > 0
            && i < pit->second.frags.size()
            && !pit->second.frags[i].empty()) {
          satisfied = true;
        }
      }
      if (satisfied) {
        it = rs.nack_state.erase(it);
        continue;
      }
      if (it->second.last_nack_ns == 0
          || (now - it->second.last_nack_ns) >= cycle_ns_) {
        if (it->second.attempts >= retx_k_recv_) {
          char b[128];
          std::snprintf(b, sizeof(b),
                        "no progress after k=%u NACKs (sender=%u s=%u i=%u)",
                        retx_k_recv_, sender, s, (unsigned)i);
          poison_reason = b;
          break;
        }
        due.emplace_back(s, i);
        it->second.last_nack_ns = now;
        it->second.attempts++;
      }
      ++it;
    }
  }
  // For-us NACK: missing_sender = the sender we lost frames from;
  // missing_target = self_id (we are the intended recipient).
  for (auto& [s, i] : due) send_nack_(sender, self_id_, s, i);
  if (!poison_reason.empty()) {
    // Receiver-side cap → POISON the sender we couldn't recover.
    mark_recv_poisoned_(sender, poison_reason);
  }
}

void BcastBus::send_nack_(uint8_t missing_sender, uint8_t missing_target,
                          uint32_t seq, uint16_t idx) {
  // 32-byte NACK: 20-byte header + 12-byte body.
  uint8_t buf[HEADER_SIZE + 12];
  const uint32_t kind = KIND_NACK;
  const uint16_t total = 0;
  const uint32_t plen = 12;
  const uint8_t r6 = 0, r7 = 0;
  const uint8_t r2_3[2] = {0, 0};
  const uint8_t r10_11[2] = {0, 0};
  const uint32_t hdr_seq = 0;       // header seq/idx unused; body has them
  const uint16_t hdr_idx = 0;
  // Header: hdr_sender = us (NACK origin); hdr_target = missing_sender
  // (whoever needs to retransmit).
  std::memcpy(buf +  0, &kind,           4);
  std::memcpy(buf +  4, &self_id_,       1);
  std::memcpy(buf +  5, &missing_sender, 1);
  std::memcpy(buf +  6, &r6,             1);
  std::memcpy(buf +  7, &r7,             1);
  std::memcpy(buf +  8, &hdr_seq,        4);
  std::memcpy(buf + 12, &hdr_idx,        2);
  std::memcpy(buf + 14, &total,          2);
  std::memcpy(buf + 16, &plen,           4);
  // Body (12 bytes, plaintext):
  buf[HEADER_SIZE + 0] = missing_sender;
  buf[HEADER_SIZE + 1] = missing_target;
  std::memcpy(buf + HEADER_SIZE + 2,  r2_3,  2);
  std::memcpy(buf + HEADER_SIZE + 4,  &seq,  4);
  std::memcpy(buf + HEADER_SIZE + 8,  &idx,  2);
  std::memcpy(buf + HEADER_SIZE + 10, r10_11, 2);

  uint64_t t_pre = 0;
  if (scheduler_) t_pre = scheduler_->wait_and_mark_pre();
  sendto(sock_, buf, HEADER_SIZE + 12, 0,
         reinterpret_cast<sockaddr*>(&bcast_addr_), sizeof(bcast_addr_));
  if (scheduler_) scheduler_->mark_post(t_pre);
  if (missing_target == self_id_) ++target_nacks_sent_;
  else                            ++witness_nacks_sent_;
}

void BcastBus::send_poison_to_target_(uint8_t target,
                                      const std::string& reason) {
  uint8_t buf[HEADER_SIZE + MAX_PAYLOAD];
  const uint32_t kind = KIND_POISON;
  const uint32_t seq = 0;
  const uint16_t idx = 0;
  const uint16_t total = 0;
  const uint8_t r6 = 0, r7 = 0;
  uint32_t plen = static_cast<uint32_t>(reason.size());
  if (plen > MAX_PAYLOAD) plen = MAX_PAYLOAD;
  std::memcpy(buf +  0, &kind,         4);
  std::memcpy(buf +  4, &self_id_,     1);
  std::memcpy(buf +  5, &target,       1);
  std::memcpy(buf +  6, &r6,           1);
  std::memcpy(buf +  7, &r7,           1);
  std::memcpy(buf +  8, &seq,          4);
  std::memcpy(buf + 12, &idx,          2);
  std::memcpy(buf + 14, &total,        2);
  std::memcpy(buf + 16, &plen,         4);
  if (plen) std::memcpy(buf + HEADER_SIZE, reason.data(), plen);
  sendto(sock_, buf, HEADER_SIZE + plen, 0,
         reinterpret_cast<sockaddr*>(&bcast_addr_), sizeof(bcast_addr_));
  mark_send_poisoned_(target, reason);
}

void BcastBus::resend_fragment_(uint8_t target, uint32_t seq, uint16_t idx,
                                const TxRecord& rec) {
  uint8_t buf[HEADER_SIZE + MAX_PAYLOAD];
  const uint32_t kind = KIND_DATA;
  const uint8_t r6 = 0, r7 = 0;
  std::memcpy(buf +  0, &kind,             4);
  std::memcpy(buf +  4, &self_id_,         1);
  std::memcpy(buf +  5, &target,           1);
  std::memcpy(buf +  6, &r6,               1);
  std::memcpy(buf +  7, &r7,               1);
  std::memcpy(buf +  8, &seq,              4);
  std::memcpy(buf + 12, &idx,              2);
  std::memcpy(buf + 14, &rec.frag_total,   2);
  std::memcpy(buf + 16, &rec.payload_len,  4);
  if (rec.payload_len) {
    std::memcpy(buf + HEADER_SIZE, rec.payload.data(), rec.payload_len);
  }
  uint64_t t_pre = 0;
  if (scheduler_) t_pre = scheduler_->wait_and_mark_pre();
  sendto(sock_, buf, HEADER_SIZE + rec.payload_len, 0,
         reinterpret_cast<sockaddr*>(&bcast_addr_), sizeof(bcast_addr_));
  if (scheduler_) scheduler_->mark_post(t_pre);
  ++tx_[target].retx_sends;
}

void BcastBus::witness_observe_(uint8_t sender, uint8_t target,
                                uint32_t seq) {
  if (sender >= nP_ || target >= nP_) return;
  WitnessState& ws = witness_[sender * nP_ + target];
  std::lock_guard<std::mutex> lg(ws.mu);
  ws.seen.insert(seq);
  if (!ws.any_seen || seq > ws.max_seen) ws.max_seen = seq;
  ws.any_seen = true;
  // Advance low_walk through any contiguous prefix of seen seqs we've
  // accumulated, so future drains don't re-walk forever.
  while (ws.seen.count(ws.low_walk)) {
    ws.seen.erase(ws.low_walk);
    ws.low_walk++;
  }
}

void BcastBus::witness_drain_(uint8_t sender, uint8_t target) {
  if (sender >= nP_ || target >= nP_) return;
  WitnessState& ws = witness_[sender * nP_ + target];
  std::vector<uint32_t> due;
  {
    std::lock_guard<std::mutex> lg(ws.mu);
    if (!ws.any_seen) return;
    // Walk [low_walk, max_seen): for any seq not seen and not already
    // NACKed, emit a one-shot witness NACK. low_walk is the high
    // water-mark of the contiguous-prefix of seen seqs (advanced in
    // witness_observe_), so this loop is bounded.
    for (uint32_t s = ws.low_walk; s < ws.max_seen; ++s) {
      if (ws.seen.count(s)) continue;
      if (ws.nacked.count(s)) continue;
      ws.nacked.insert(s);
      due.push_back(s);
    }
  }
  for (uint32_t s : due) {
    // missing_sender = the sender we're witnessing; missing_target =
    // the intended target (NOT us). On the wire this NACK has
    // hdr_target = missing_sender, but the body's missing_target_id
    // is target (so the original sender's origin check correctly
    // identifies this as a witness NACK and drops it).
    send_nack_(sender, target, s, /*idx=*/0);
  }
}

void BcastBus::mark_recv_poisoned_(uint8_t sender,
                                   const std::string& reason) {
  RxState& rs = rx_[sender];
  if (rs.poisoned.exchange(true, std::memory_order_acq_rel)) return;
  std::fprintf(stderr,
               "BcastBus[p=%u]: rx[%u] POISONED — %s\n",
               self_id_, sender, reason.c_str());
  rs.cv.notify_all();
}

void BcastBus::throw_if_recv_poisoned_(uint8_t sender) {
  if (rx_[sender].poisoned.load(std::memory_order_acquire)) {
    throw ChannelPoisonedError("rx pipe poisoned");
  }
}

void BcastBus::mark_send_poisoned_(uint8_t target,
                                   const std::string& reason) {
  TxState& ts = tx_[target];
  if (ts.poisoned.exchange(true, std::memory_order_acq_rel)) return;
  std::fprintf(stderr,
               "BcastBus[p=%u]: tx[%u] POISONED — %s\n",
               self_id_, target, reason.c_str());
}

void BcastBus::throw_if_send_poisoned_(uint8_t target) {
  if (tx_[target].poisoned.load(std::memory_order_acquire)) {
    throw ChannelPoisonedError("tx pipe poisoned");
  }
}

}  // namespace io
