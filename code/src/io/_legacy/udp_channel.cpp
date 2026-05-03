#include "udp_channel.h"
#include "../net/tdma_scheduler.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
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
  std::fprintf(stderr, "UDPChannel: %s: %s\n", what, std::strerror(errno));
  throw std::runtime_error(std::string("UDPChannel: ") + what);
}

}  // namespace

void UDPChannel::set_scheduler(net::TDMAScheduler* s) {
  scheduler_ = s;
  if (s && s->slot_ns() > 0 && s->cycle_slots() > 0) {
    cycle_ns_ = s->slot_ns() * static_cast<uint64_t>(s->cycle_slots());
  }
  // else: keep the 100 ms default — it's only used as the receiver's
  // re-NACK interval, and a sane default works when TDMA is off.
}

UDPChannel::UDPChannel(const std::string& peer_ip, int port) {
  sock_ = socket(AF_INET, SOCK_DGRAM, 0);
  if (sock_ < 0) die("socket");

  int one = 1;
  setsockopt(sock_, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

  // Enlarge kernel buffers: MPC bursts can dwarf the default 208 KB.
  int bufsz = 8 * 1024 * 1024;
  setsockopt(sock_, SOL_SOCKET, SO_RCVBUF, &bufsz, sizeof(bufsz));
  setsockopt(sock_, SOL_SOCKET, SO_SNDBUF, &bufsz, sizeof(bufsz));

  sockaddr_in local{};
  local.sin_family = AF_INET;
  local.sin_addr.s_addr = htonl(INADDR_ANY);
  local.sin_port = htons(static_cast<uint16_t>(port));
  if (bind(sock_, reinterpret_cast<sockaddr*>(&local), sizeof(local)) < 0) {
    die("bind");
  }

  peer_.sin_family = AF_INET;
  peer_.sin_port = htons(static_cast<uint16_t>(port));
  if (inet_pton(AF_INET, peer_ip.c_str(), &peer_.sin_addr) != 1) {
    die("inet_pton");
  }
}

UDPChannel::~UDPChannel() {
  if (pump_running_.load()) {
    pump_stop_.store(true, std::memory_order_relaxed);
    if (pump_thread_.joinable()) pump_thread_.join();
  }
  if (sock_ >= 0) close(sock_);
  // Emit profile counters. One line per channel; filterable via grep.
  std::fprintf(stderr,
               "UDPChannel: peer=%s:%u tx_dg=%lu rx_dg=%lu "
               "ns_send=%lu ns_recv_data=%lu ns_recvfrom=%lu "
               "ns_drain=%lu ns_out_copy=%lu bytes=%lu "
               "tx_buf_streams=%zu tx_buf_evict=%lu retx_sends=%lu\n",
               inet_ntoa(peer_.sin_addr), (unsigned)ntohs(peer_.sin_port),
               (unsigned long)datagrams_tx_, (unsigned long)datagrams_rx_,
               (unsigned long)ns_send_, (unsigned long)ns_recv_data_,
               (unsigned long)ns_recvfrom_, (unsigned long)ns_drain_,
               (unsigned long)ns_out_memcpy_, (unsigned long)counter,
               tx_buf_order_.size(),
               (unsigned long)tx_buf_evictions_,
               (unsigned long)retx_sends_);
}

void UDPChannel::send_data(const void* data, size_t len) {
  throw_if_poisoned_();
  const uint64_t t0_send = now_ns_mono();
  const auto* src = static_cast<const uint8_t*>(data);
  const uint32_t seq = tx_seq_++;
  const uint32_t total = len == 0
      ? 1u
      : static_cast<uint32_t>((len + MAX_PAYLOAD - 1) / MAX_PAYLOAD);

  uint8_t buf[HEADER_SIZE + MAX_PAYLOAD];
  size_t off = 0;
  for (uint32_t i = 0; i < total; ++i) {
    uint64_t t_pre = 0;
    if (scheduler_) t_pre = scheduler_->wait_and_mark_pre();
    size_t chunk = std::min<size_t>(MAX_PAYLOAD, len - off);
    const uint32_t kind = KIND_DATA;
    const uint32_t payload_len = static_cast<uint32_t>(chunk);
    const uint16_t idx = static_cast<uint16_t>(i);
    const uint16_t tot16 = static_cast<uint16_t>(total);
    std::memcpy(buf +  0, &kind,        4);
    std::memcpy(buf +  4, &seq,         4);
    std::memcpy(buf +  8, &idx,         2);
    std::memcpy(buf + 10, &tot16,       2);
    std::memcpy(buf + 12, &payload_len, 4);
    if (chunk) std::memcpy(buf + HEADER_SIZE, src + off, chunk);

    // Retain a copy in tx_buf_ before sendto() — even if sendto fails
    // and we retry on EAGAIN, the record is in place. Stage 3 reads
    // these records when a NACK arrives. Skipped entirely when
    // retx_disabled_ (Stage 5 bypass) — the channel reverts to plain
    // UDP with no recovery.
    if (!retx_disabled_.load(std::memory_order_relaxed)) {
      std::lock_guard<std::mutex> lg(tx_mu_);
      TxRecord rec;
      rec.frag_total = tot16;
      rec.payload_len = payload_len;
      if (chunk) rec.payload.assign(src + off, src + off + chunk);
      const auto key = std::make_pair(seq, idx);
      tx_buf_[key] = std::move(rec);
      // Track stream_seqs for FIFO eviction. Push only on the first
      // fragment of each stream so order_ holds at most one entry per
      // stream_seq.
      if (i == 0) {
        tx_buf_order_.push_back(seq);
        while (tx_buf_order_.size() > TX_BUF_CAP_STREAMS) {
          uint32_t old = tx_buf_order_.front();
          tx_buf_order_.pop_front();
          // Erase every fragment of this evicted stream_seq.
          auto lo = tx_buf_.lower_bound({old, 0});
          auto hi = tx_buf_.upper_bound({old, UINT16_MAX});
          tx_buf_.erase(lo, hi);
          ++tx_buf_evictions_;
        }
      }
    }

    ssize_t n = sendto(sock_, buf, HEADER_SIZE + chunk, 0,
                       reinterpret_cast<sockaddr*>(&peer_), sizeof(peer_));
    if (n < 0) {
      // EAGAIN under buffer pressure: spin briefly.
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        std::this_thread::sleep_for(std::chrono::microseconds(10));
        --i; continue;
      }
      die("sendto");
    }
    if (scheduler_) scheduler_->mark_post(t_pre);
    ++datagrams_tx_;
    off += chunk;
    if (len == 0) break;
  }
  counter += len;
  ns_send_ += now_ns_mono() - t0_send;
}

// Synchronous single-datagram receive (used when pump is off).
void UDPChannel::receive_one() {
  uint8_t buf[HEADER_SIZE + MAX_PAYLOAD + 64];
  const uint64_t t0_rf = now_ns_mono();
  ssize_t n = recvfrom(sock_, buf, sizeof(buf), 0, nullptr, nullptr);
  ns_recvfrom_ += now_ns_mono() - t0_rf;
  if (n < 0) {
    if (errno == EINTR) return;
    die("recvfrom");
  }
  ++datagrams_rx_;
  process_datagram(buf, n);
}

// Core reassembly. Caller MUST hold rx_mu_ when pump is running; when
// pump is off and this is called directly from receive_one(), there's
// no concurrent access so the lock is a no-op cost.
void UDPChannel::process_datagram(const uint8_t* buf, ssize_t n) {
  if (n == 4) {
    uint32_t m;
    std::memcpy(&m, buf, 4);
    if (m == SYNC_MAGIC) return;  // stale sync magic; drop
  }
  if (n < static_cast<ssize_t>(HEADER_SIZE)) {
    std::fprintf(stderr, "UDPChannel: short datagram n=%zd\n", n);
    return;
  }
  uint32_t kind, seq, payload_len;
  uint16_t idx, total;
  std::memcpy(&kind,        buf +  0, 4);
  std::memcpy(&seq,         buf +  4, 4);
  std::memcpy(&idx,         buf +  8, 2);
  std::memcpy(&total,       buf + 10, 2);
  std::memcpy(&payload_len, buf + 12, 4);
  if (kind == KIND_NACK) {
    // Should never reach here: pump_loop intercepts NACKs before
    // calling process_datagram. Drop defensively.
    return;
  }
  if (kind != KIND_DATA) {
    // KIND_POISON not yet handled. Stage 4 installs dispatch here.
    std::fprintf(stderr, "UDPChannel: unsupported kind=%u (drop)\n", kind);
    return;
  }
  if (n != static_cast<ssize_t>(HEADER_SIZE + payload_len)) {
    std::fprintf(stderr, "UDPChannel: hdr len mismatch n=%zd payload=%u\n",
                 n, payload_len);
    return;
  }
  // Track highest stream_seq we've seen on the wire — gap detection
  // (compute_missing_locked_) walks [next_rx_stream_, max_seen_seq_].
  if (!any_seen_ || seq > max_seen_seq_) {
    max_seen_seq_ = seq;
    any_seen_ = true;
  }
  // If this fragment fills a NACK we had pending, drop the NACK entry.
  // Cheap: just erase the (seq, idx) key if present.
  nack_state_.erase({seq, idx});
  if (seq < next_rx_stream_) return;  // late duplicate

  // Fast path: a single-fragment datagram that's also the next stream
  // we're waiting for.
  if (total == 1 && seq == next_rx_stream_) {
    if (payload_len > 0) {
      Chunk c;
      c.bytes.assign(buf + HEADER_SIZE, buf + HEADER_SIZE + payload_len);
      rx_bytes_ += payload_len;
      rx_.push_back(std::move(c));
    }
    next_rx_stream_++;
    drain_pending_locked();
    return;
  }

  auto& p = pending_[seq];
  if (p.frag_total == 0) {
    p.frag_total = total;
    p.frags.resize(total);
  }
  if (idx >= p.frag_total) {
    std::fprintf(stderr, "UDPChannel: bad idx %u >= total %u\n",
                 idx, p.frag_total);
    return;
  }
  if (!p.frags[idx].empty() || payload_len == 0) {
    if (payload_len == 0) p.received++;
  } else {
    p.frags[idx].assign(buf + HEADER_SIZE, buf + HEADER_SIZE + payload_len);
    p.received++;
  }

  drain_pending_locked();
}

void UDPChannel::pump_loop() {
  // Timed recv so the pump can observe pump_stop_ periodically AND
  // tick the NACK retry drain on idle ticks too.
  set_rcv_timeout(sock_, 100'000);  // 100 ms
  uint8_t buf[HEADER_SIZE + MAX_PAYLOAD + 64];
  while (!pump_stop_.load(std::memory_order_relaxed)) {
    const uint64_t t0_rf = now_ns_mono();
    ssize_t n = recvfrom(sock_, buf, sizeof(buf), 0, nullptr, nullptr);
    ns_recvfrom_ += now_ns_mono() - t0_rf;
    if (n < 0) {
      if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
        // Timeout — fall through to drain_nack_state_().
      } else {
        std::fprintf(stderr, "UDPChannel pump: recvfrom errno=%d\n", errno);
        break;
      }
    } else if (n > 0) {
      // Peek at the kind without taking any lock — KIND_NACK,
      // KIND_POISON, and KIND_DATA take different paths.
      if (n >= static_cast<ssize_t>(HEADER_SIZE)) {
        uint32_t kind;
        std::memcpy(&kind, buf, 4);
        if (kind == KIND_NACK) {
          uint32_t s;
          uint16_t i;
          std::memcpy(&s, buf + 4, 4);
          std::memcpy(&i, buf + 8, 2);
          handle_incoming_nack_(s, i);
        } else if (kind == KIND_POISON) {
          // Peer told us they gave up. Pull the reason payload and
          // mark this channel poisoned so the protocol thread throws.
          uint32_t payload_len;
          std::memcpy(&payload_len, buf + 12, 4);
          if (payload_len > MAX_PAYLOAD) payload_len = 0;
          std::string reason(reinterpret_cast<const char*>(buf + HEADER_SIZE),
                             payload_len);
          mark_poisoned_(std::string("peer POISON: ") + reason);
        } else {
          std::lock_guard<std::mutex> lg(rx_mu_);
          ++datagrams_rx_;
          process_datagram(buf, n);
        }
      } else {
        // Short datagram (e.g. stale 4-byte sync magic). Existing
        // process_datagram handles n==4 specially.
        std::lock_guard<std::mutex> lg(rx_mu_);
        ++datagrams_rx_;
        process_datagram(buf, n);
      }
      rx_cv_.notify_all();
      // NOTE: drain_nack_state_ is intentionally NOT called on every
      // datagram. Bursts (e.g. a 115-fragment broadcast layer) would
      // trigger 115 drain ticks within milliseconds, and the gap
      // detector would briefly observe partial-stream gaps between
      // frags that are still in flight, racing the grace period.
      // Drain only fires below on the recvfrom timeout (~100 ms) —
      // by then bursts have settled and only real loss remains.
    } else {
      // recvfrom timeout — quiescent network. Safe time to scan for
      // gaps and emit NACKs. Skip if poisoned or if retx is bypassed.
      if (!poisoned_.load(std::memory_order_relaxed) &&
          !retx_disabled_.load(std::memory_order_relaxed)) {
        drain_nack_state_();
      }
    }
  }
}

// ---- Stage 3: NACK + retransmit ----------------------------------------

void UDPChannel::compute_missing_locked_() {
  // rx_mu_ held.
  if (!any_seen_) return;
  // Grace period for newly-discovered gaps: set last_nack_ns to "now"
  // on entry creation so the first NACK fires only after a full
  // cycle_ns has elapsed. This gives in-flight bursts time to drain
  // before we falsely accuse the network of dropping. Without this,
  // every burst layer triggers spurious NACKs at the next 100 ms tick.
  const uint64_t now = now_ns_mono();
  for (uint32_t s = next_rx_stream_; s <= max_seen_seq_; ++s) {
    auto pit = pending_.find(s);
    if (pit == pending_.end()) {
      // No fragment of stream s has arrived yet. NACK frag 0 to learn
      // frag_total — but wait one cycle first.
      auto [it, inserted] = nack_state_.try_emplace(
          std::make_pair(s, uint16_t{0}));
      if (inserted) it->second.last_nack_ns = now;
    } else {
      const Partial& part = pit->second;
      if (part.frag_total == 0) continue;
      for (uint16_t i = 0; i < part.frag_total; ++i) {
        if (part.frags[i].empty()) {
          auto [it, inserted] = nack_state_.try_emplace(
              std::make_pair(s, i));
          if (inserted) it->second.last_nack_ns = now;
        }
      }
    }
  }
}

void UDPChannel::drain_nack_state_() {
  // Walk nack_state_, drop satisfied entries, collect those that are
  // due for (re)NACK. Inside the lock we only mutate state — actual
  // sendto happens outside the lock so the gate wait doesn't hold up
  // recv_data's wait_for_data condition variable.
  if (poisoned_.load(std::memory_order_relaxed)) return;
  std::vector<std::pair<uint32_t, uint16_t>> due;
  std::string poison_reason;
  {
    std::lock_guard<std::mutex> lg(rx_mu_);
    compute_missing_locked_();
    const uint64_t now = now_ns_mono();
    for (auto it = nack_state_.begin(); it != nack_state_.end(); ) {
      const uint32_t s = it->first.first;
      const uint16_t i = it->first.second;
      // Satisfied? next_rx_stream_ has advanced past s, OR pending_[s]
      // has filled in frag i.
      bool satisfied = (s < next_rx_stream_);
      if (!satisfied) {
        auto pit = pending_.find(s);
        if (pit != pending_.end() && pit->second.frag_total > 0 &&
            i < pit->second.frags.size() && !pit->second.frags[i].empty()) {
          satisfied = true;
        }
      }
      if (satisfied) {
        it = nack_state_.erase(it);
        continue;
      }
      // Due for (re)NACK?
      if (it->second.last_nack_ns == 0 ||
          (now - it->second.last_nack_ns) >= cycle_ns_) {
        if (it->second.attempts >= retx_k_recv_) {
          // We've already asked k times. Stage 4: trip POISON.
          char buf[128];
          std::snprintf(buf, sizeof(buf),
                        "no progress after k=%u NACKs on (s=%u, i=%u)",
                        retx_k_recv_, s, (unsigned)i);
          poison_reason = buf;
          break;
        }
        due.emplace_back(s, i);
        it->second.last_nack_ns = now;
        it->second.attempts++;
      }
      ++it;
    }
  }
  for (const auto& [s, i] : due) {
    send_nack_(s, i);
  }
  if (!poison_reason.empty()) {
    send_poison_(poison_reason);
  }
}

void UDPChannel::send_nack_(uint32_t s, uint16_t i) {
  // Header-only datagram, kind=NACK, stream_seq and frag_idx hold the
  // (s, i) being requested. payload_len=0 so total length = HEADER_SIZE.
  uint8_t buf[HEADER_SIZE];
  const uint32_t kind = KIND_NACK;
  const uint16_t total = 0;
  const uint32_t payload_len = 0;
  std::memcpy(buf +  0, &kind,        4);
  std::memcpy(buf +  4, &s,           4);
  std::memcpy(buf +  8, &i,           2);
  std::memcpy(buf + 10, &total,       2);
  std::memcpy(buf + 12, &payload_len, 4);
  uint64_t t_pre = 0;
  if (scheduler_) t_pre = scheduler_->wait_and_mark_pre();
  ssize_t n = sendto(sock_, buf, HEADER_SIZE, 0,
                     reinterpret_cast<sockaddr*>(&peer_), sizeof(peer_));
  if (scheduler_) scheduler_->mark_post(t_pre);
  if (n < 0) {
    std::fprintf(stderr, "UDPChannel: send_nack errno=%d\n", errno);
  }
  // counter does NOT bump — NACK is not application data.
}

void UDPChannel::handle_incoming_nack_(uint32_t s, uint16_t i) {
  // Sender side. Look up the requested fragment in tx_buf_, bump
  // nack_count, and either resend or POISON if the cap has been hit.
  if (poisoned_.load(std::memory_order_relaxed)) return;
  if (retx_disabled_.load(std::memory_order_relaxed)) {
    // Bypass: log and drop. Don't trip POISON — the bypass is only
    // for A/B benchmarking and the workload should be loss-free
    // anyway. If the peer is sending NACKs the test setup is wrong.
    std::fprintf(stderr,
                 "UDPChannel: retx disabled, ignoring NACK (s=%u, i=%u)\n",
                 s, (unsigned)i);
    return;
  }
  TxRecord rec_copy;
  bool found = false;
  bool over_cap = false;
  {
    std::lock_guard<std::mutex> lg(tx_mu_);
    auto it = tx_buf_.find({s, i});
    if (it != tx_buf_.end()) {
      ++it->second.nack_count;
      if (it->second.nack_count > retx_k_send_) {
        over_cap = true;
      } else {
        rec_copy = it->second;  // copy out so we sendto outside the lock
        found = true;
      }
    }
  }
  if (over_cap) {
    char reason[128];
    std::snprintf(reason, sizeof(reason),
                  "peer exceeded retx budget on (s=%u, i=%u)", s, (unsigned)i);
    send_poison_(reason);
    return;
  }
  if (!found) {
    char reason[128];
    std::snprintf(reason, sizeof(reason),
                  "NACK for evicted (s=%u, i=%u)", s, (unsigned)i);
    send_poison_(reason);
    return;
  }
  resend_fragment_(s, i, rec_copy);
}

// ---- Stage 4: POISON helpers + cap trip path --------------------------

void UDPChannel::throw_if_poisoned_() {
  if (poisoned_.load(std::memory_order_acquire)) {
    throw ChannelPoisonedError("channel poisoned");
  }
}

void UDPChannel::mark_poisoned_(const std::string& reason) {
  if (poisoned_.exchange(true, std::memory_order_acq_rel)) return;  // already
  std::fprintf(stderr,
               "UDPChannel: peer=%s:%u POISONED — %s\n",
               inet_ntoa(peer_.sin_addr), (unsigned)ntohs(peer_.sin_port),
               reason.c_str());
  // Wake any recv_data() blocked on rx_cv_ so it can throw.
  rx_cv_.notify_all();
}

void UDPChannel::send_poison_(const std::string& reason) {
  if (poisoned_.load(std::memory_order_relaxed)) return;
  uint8_t buf[HEADER_SIZE + MAX_PAYLOAD];
  const uint32_t kind = KIND_POISON;
  const uint32_t seq = 0;        // unused for POISON
  const uint16_t idx = 0;
  const uint16_t total = 0;
  const std::string& r = reason;
  uint32_t payload_len = static_cast<uint32_t>(r.size());
  if (payload_len > MAX_PAYLOAD) payload_len = MAX_PAYLOAD;
  std::memcpy(buf +  0, &kind,        4);
  std::memcpy(buf +  4, &seq,         4);
  std::memcpy(buf +  8, &idx,         2);
  std::memcpy(buf + 10, &total,       2);
  std::memcpy(buf + 12, &payload_len, 4);
  if (payload_len) std::memcpy(buf + HEADER_SIZE, r.data(), payload_len);
  // POISON bypasses the TDMA gate intentionally — we want to abort
  // fast, not wait for the next own slot.
  ssize_t n = sendto(sock_, buf, HEADER_SIZE + payload_len, 0,
                     reinterpret_cast<sockaddr*>(&peer_), sizeof(peer_));
  if (n < 0) {
    std::fprintf(stderr, "UDPChannel: send_poison errno=%d\n", errno);
  }
  // Mark local state poisoned even if sendto failed.
  mark_poisoned_(reason);
}

// ---- Stage 3 helper, original definition -----------------------------

void UDPChannel::resend_fragment_(uint32_t s, uint16_t i, const TxRecord& rec) {
  // Replay one fragment as KIND_DATA. Same on-wire shape as a fresh
  // send, so the receiver's process_datagram path consumes it without
  // any retx-aware code (dedupe is implicit via pending_[s].frags[i]).
  uint8_t buf[HEADER_SIZE + MAX_PAYLOAD];
  const uint32_t kind = KIND_DATA;
  std::memcpy(buf +  0, &kind,             4);
  std::memcpy(buf +  4, &s,                4);
  std::memcpy(buf +  8, &i,                2);
  std::memcpy(buf + 10, &rec.frag_total,   2);
  std::memcpy(buf + 12, &rec.payload_len,  4);
  if (rec.payload_len) {
    std::memcpy(buf + HEADER_SIZE, rec.payload.data(), rec.payload_len);
  }
  uint64_t t_pre = 0;
  if (scheduler_) t_pre = scheduler_->wait_and_mark_pre();
  ssize_t n = sendto(sock_, buf, HEADER_SIZE + rec.payload_len, 0,
                     reinterpret_cast<sockaddr*>(&peer_), sizeof(peer_));
  if (scheduler_) scheduler_->mark_post(t_pre);
  if (n < 0) {
    std::fprintf(stderr, "UDPChannel: resend_fragment errno=%d\n", errno);
    return;
  }
  ++datagrams_tx_;
  ++retx_sends_;
  // counter is application bytes — DON'T double-count on retx.
}

void UDPChannel::start_recv_pump() {
  if (pump_running_.exchange(true)) return;  // already started
  pump_thread_ = std::thread(&UDPChannel::pump_loop, this);
}

void UDPChannel::drain_pending_locked() {
  while (true) {
    auto it = pending_.find(next_rx_stream_);
    if (it == pending_.end()) break;
    if (it->second.received != it->second.frag_total) break;

    const uint64_t t0_d = now_ns_mono();
    // Concatenate the stream's fragments into a single chunk so
    // recv_data can memcpy from one contiguous buffer.
    size_t total_bytes = 0;
    for (const auto& f : it->second.frags) total_bytes += f.size();
    if (total_bytes > 0) {
      Chunk c;
      c.bytes.reserve(total_bytes);
      for (auto& f : it->second.frags) {
        c.bytes.insert(c.bytes.end(), f.begin(), f.end());
      }
      rx_bytes_ += total_bytes;
      rx_.push_back(std::move(c));
    }
    pending_.erase(it);
    next_rx_stream_++;
    ns_drain_ += now_ns_mono() - t0_d;
  }
}

void UDPChannel::recv_data(void* data, size_t len) {
  throw_if_poisoned_();
  const uint64_t t0_rd = now_ns_mono();
  auto* dst = static_cast<uint8_t*>(data);
  size_t remaining = len;

  if (pump_running_.load(std::memory_order_relaxed)) {
    // Async path: pump feeds rx_ from its own thread; we block on cv.
    // Wake-up condition includes poisoned_ so a remote POISON or local
    // cap trip can unblock a stuck recv_data.
    std::unique_lock<std::mutex> lk(rx_mu_);
    rx_cv_.wait(lk, [this, &remaining] {
      return rx_bytes_ >= remaining ||
             poisoned_.load(std::memory_order_relaxed);
    });
    if (poisoned_.load(std::memory_order_relaxed)) {
      // Drop lock before throwing; caller's stack unwinds.
      lk.unlock();
      throw_if_poisoned_();
    }
    const uint64_t t0_cp = now_ns_mono();
    while (remaining > 0) {
      Chunk& front = rx_.front();
      size_t avail = front.bytes.size() - front.offset;
      size_t take = (remaining < avail) ? remaining : avail;
      std::memcpy(dst + (len - remaining),
                  front.bytes.data() + front.offset, take);
      front.offset += take;
      remaining -= take;
      rx_bytes_ -= take;
      if (front.offset == front.bytes.size()) rx_.pop_front();
    }
    ns_out_memcpy_ += now_ns_mono() - t0_cp;
  } else {
    // Synchronous fallback (pump not armed).
    while (rx_bytes_ < len) receive_one();
    const uint64_t t0_cp = now_ns_mono();
    while (remaining > 0) {
      Chunk& front = rx_.front();
      size_t avail = front.bytes.size() - front.offset;
      size_t take = (remaining < avail) ? remaining : avail;
      std::memcpy(dst + (len - remaining),
                  front.bytes.data() + front.offset, take);
      front.offset += take;
      remaining -= take;
      rx_bytes_ -= take;
      if (front.offset == front.bytes.size()) rx_.pop_front();
    }
    ns_out_memcpy_ += now_ns_mono() - t0_cp;
  }
  ns_recv_data_ += now_ns_mono() - t0_rd;
}

void UDPChannel::sync() {
  const uint32_t magic = SYNC_MAGIC;
  bool saw_peer = false;
  // Short timeout + spam: each iteration sends a SYN and tries to drain
  // any pending datagrams. We break after seeing at least one peer SYN.
  set_rcv_timeout(sock_, 50'000);  // 50 ms
  for (int attempt = 0; attempt < 400 && !saw_peer; ++attempt) {
    sendto(sock_, &magic, 4, 0,
           reinterpret_cast<sockaddr*>(&peer_), sizeof(peer_));
    uint32_t got;
    ssize_t n = recvfrom(sock_, &got, 4, 0, nullptr, nullptr);
    if (n == 4 && got == SYNC_MAGIC) saw_peer = true;
  }
  if (!saw_peer) {
    std::fprintf(stderr, "UDPChannel::sync timed out\n");
  }
  // Keep sending briefly so the peer is guaranteed to see at least one
  // of our SYNs too, even if its sync() returned before ours started.
  for (int i = 0; i < 4; ++i) {
    sendto(sock_, &magic, 4, 0,
           reinterpret_cast<sockaddr*>(&peer_), sizeof(peer_));
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  // Drain any leftover sync datagrams from the kernel buffer so they
  // don't confuse the first recv_data.
  set_rcv_timeout(sock_, 20'000);
  while (true) {
    uint8_t tmp[16];
    ssize_t n = recvfrom(sock_, tmp, sizeof(tmp), 0, nullptr, nullptr);
    if (n <= 0) break;
    if (n != 4) {
      // Not a sync datagram — a data datagram leaked in. Re-inject it
      // by putting it back through the receive pipeline... in practice
      // this shouldn't happen because sync precedes data, but if it
      // does we abort loudly.
      std::fprintf(stderr, "UDPChannel::sync saw non-sync dgram n=%zd\n", n);
      break;
    }
  }
  // Restore blocking recv.
  timeval zero{};
  setsockopt(sock_, SOL_SOCKET, SO_RCVTIMEO, &zero, sizeof(zero));
}

}  // namespace io
