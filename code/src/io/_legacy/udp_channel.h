#pragma once

#include <netinet/in.h>

#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <map>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace net { class TDMAScheduler; }

namespace io {

// Thrown when a channel has been poisoned — either we tripped one of
// our caps or the peer sent us POISON. Catchable as std::exception
// via the existing top-level handler in benchmark drivers; the what()
// string is the reason.
class ChannelPoisonedError : public std::runtime_error {
 public:
  explicit ChannelPoisonedError(const std::string& msg)
      : std::runtime_error(msg) {}
};

// UDP-backed drop-in for the subset of emp::NetIO that NetIOMP uses.
//
// Wire format per datagram (see RETRANSMIT_PLAN.md for the design):
//   [header 16B][payload 0..MAX_PAYLOAD]
//   header = {uint32 kind, uint32 stream_seq, uint16 frag_idx,
//             uint16 frag_total, uint32 payload_len}
//
// `kind` distinguishes DATA from control datagrams (NACK, POISON);
// only DATA is exchanged today — Stage 1 of the retransmit plan only
// extends the wire so later stages can layer in. `kind != DATA` is
// dropped with a warning until the relevant handlers ship.
//
// A single send_data(buf, N) call produces ceil(N/MAX_PAYLOAD) DATA
// datagrams sharing the same stream_seq. The receiver reassembles per
// stream_seq and releases fully-assembled streams into an in-order
// byte queue.
//
// No ACKs, no retransmission yet. Under the "assume no loss" premise,
// a missing datagram parks recv_data forever. Loss handling lands in
// Stages 3-4.
//
// sync(): exchange a 4-byte magic datagram with the peer to prove the
// socket pair is alive after initial bind. Spam-retransmit because the
// first few sync datagrams can race against the peer's bind(). The
// 4-byte sync datagram is NOT a 16-byte header so process_datagram
// distinguishes by length before parsing.
class UDPChannel {
 public:
  static constexpr size_t MAX_PAYLOAD = 1400;
  static constexpr size_t HEADER_SIZE = 16;
  static constexpr uint32_t SYNC_MAGIC = 0xBEEFCAFEu;

  // Wire kinds (first 4 bytes of header).
  static constexpr uint32_t KIND_DATA   = 0;
  static constexpr uint32_t KIND_NACK   = 1;  // reserved for Stage 3
  static constexpr uint32_t KIND_POISON = 2;  // reserved for Stage 4

  // Bind a UDP socket locally on `port` and remember the peer's
  // (ip, port) for sendto. Our pairing convention binds both endpoints
  // to the same `port` number; different IPs keep the sockets distinct.
  UDPChannel(const std::string& peer_ip, int port);
  ~UDPChannel();

  // Optional TDMA gate. If set, send_data() calls scheduler->wait_for_slot()
  // before each datagram. sync() is intentionally NOT gated so the startup
  // handshake doesn't inherit TDMA latency. Also derives cycle_ns_ from
  // the scheduler — Stage 3 uses it as the receiver-side re-NACK rhythm.
  void set_scheduler(net::TDMAScheduler* s);

  UDPChannel(const UDPChannel&) = delete;
  UDPChannel& operator=(const UDPChannel&) = delete;

  // emp::NetIO-compatible surface used by NetIOMP.
  void send_data(const void* data, size_t len);
  void recv_data(void* data, size_t len);
  void flush() {}
  void sync();
  void set_nodelay() {}

  // Arm the background recv-pump thread. Must be called exactly once
  // AFTER sync() (which does its own blocking recvfrom). Safe to skip
  // — recv_data() falls back to synchronous recvfrom if the pump is off.
  void start_recv_pump();

  // Total application bytes transmitted on this channel (matches the
  // semantic of emp::NetIO::counter used by benchmark reporting).
  uint64_t counter = 0;

  // Cheap profiling counters (accumulators in ns; 2 clock_gettime per call).
  uint64_t ns_send_ = 0;          // time in send_data (incl. TDMA gate, memcpy, sendto)
  uint64_t ns_recv_data_ = 0;     // total time in recv_data
  uint64_t ns_recvfrom_ = 0;      // time blocked in recvfrom syscall (subset of ns_recv_data_)
  uint64_t ns_drain_ = 0;         // time in drain_pending concat copy (subset)
  uint64_t ns_out_memcpy_ = 0;    // time in recv_data memcpy out to caller (subset)
  uint64_t datagrams_rx_ = 0;
  uint64_t datagrams_tx_ = 0;

  // Retransmit telemetry (Stage 2 retains data; Stage 3 will read it
  // from the NACK handler).
  uint64_t tx_buf_evictions_ = 0;  // count of stream_seqs aged out before any NACK
  uint64_t retx_sends_ = 0;        // count of resends triggered by a NACK (Stage 3)

 private:
  int sock_ = -1;
  sockaddr_in peer_{};
  net::TDMAScheduler* scheduler_ = nullptr;

  uint32_t tx_seq_ = 0;
  uint32_t next_rx_stream_ = 0;

  struct Partial {
    uint32_t frag_total = 0;
    uint32_t received = 0;
    std::vector<std::vector<uint8_t>> frags;
  };
  // Streams that have begun arriving but aren't yet ready to hand to
  // the byte queue (either incomplete or waiting for an earlier stream
  // to finish so ordering is preserved).
  std::map<uint32_t, Partial> pending_;

  // Queue of completed streams' bytes. Each `Chunk` is one logical
  // send_data() call's payload, with `offset` tracking how many bytes
  // of the front chunk have already been delivered. recv_data() walks
  // chunks with memcpy instead of byte-by-byte deque ops.
  struct Chunk {
    std::vector<uint8_t> bytes;
    size_t offset = 0;
  };
  std::deque<Chunk> rx_;
  size_t rx_bytes_ = 0;  // sum of (bytes.size() - offset) across rx_

  // Guards rx_, rx_bytes_, pending_, next_rx_stream_ between the
  // background pump thread and caller-thread recv_data().
  std::mutex rx_mu_;
  std::condition_variable rx_cv_;
  std::thread pump_thread_;
  std::atomic<bool> pump_running_{false};
  std::atomic<bool> pump_stop_{false};

  // Sender-side retain buffer. Each TxRecord is one fragment we
  // emitted, kept around in case a NACK arrives asking us to resend.
  // Bounded by TX_BUF_CAP stream_seqs; oldest stream_seq evicted when
  // we exceed the cap. Indexed by (stream_seq, frag_idx). Stage 2
  // populates and evicts; Stage 3 reads on NACK arrival.
  static constexpr size_t TX_BUF_CAP_STREAMS = 4096;
  struct TxRecord {
    uint16_t frag_total = 0;
    uint32_t payload_len = 0;
    std::vector<uint8_t> payload;
    uint32_t nack_count = 0;       // bumped only on NACK arrival (Stage 4)
  };
  std::map<std::pair<uint32_t, uint16_t>, TxRecord> tx_buf_;
  std::deque<uint32_t> tx_buf_order_;   // FIFO of stream_seqs for eviction
  std::mutex tx_mu_;                    // guards tx_buf_ + tx_buf_order_

  // Receiver-side NACK state (Stage 3). One entry per missing fragment.
  // Created on gap detection; erased once the fragment has arrived
  // (or once next_rx_stream_ has advanced past it). Each entry holds
  // the count of NACKs THIS receiver has sent for this fragment so
  // far — Stage 4 trips POISON on `attempts >= retx_k_recv_`.
  struct NackRecord {
    uint32_t attempts = 0;          // NACKs sent so far
    uint64_t last_nack_ns = 0;      // CLOCK_MONOTONIC at last send
  };
  std::map<std::pair<uint32_t, uint16_t>, NackRecord> nack_state_;
  uint32_t max_seen_seq_ = 0;       // highest stream_seq we've witnessed
  bool any_seen_ = false;           // disambiguates max_seen_seq_=0 (init)
  uint64_t cycle_ns_ = 100'000'000; // re-NACK rhythm; set in set_scheduler

  // Stage 4: dual caps + POISON.
  // - retx_k_send_: max NACKs we will answer FROM this peer for any
  //   single (stream_seq, frag_idx) before sending POISON.
  // - retx_k_recv_: max NACKs we will SEND for any single fragment
  //   before sending POISON.
  // Both default to 5; Stage 5 hooks env-var setters.
  uint32_t retx_k_send_ = 5;
  uint32_t retx_k_recv_ = 5;
  std::atomic<bool> poisoned_{false};

  // Stage 5: bypass flag. When set, the channel skips Stage-2..4
  // logic entirely:
  //  - send_data does not retain a copy in tx_buf_
  //  - pump_loop does not run drain_nack_state_
  //  - inbound NACKs are logged + dropped (no POISON trip)
  // Inbound POISON is still honoured — a peer telling us they have
  // given up is not something we can ignore. Useful for A/B
  // benchmarking the retx layer's overhead vs the Phase-2 UDP path.
  std::atomic<bool> retx_disabled_{false};

 public:
  // Stage 5 setters: called by NetIOMP from env-var values once it
  // has constructed the channel. Default values match the pre-Stage-5
  // behavior so anything that doesn't call them keeps working.
  void set_retx_k_send(uint32_t k)   { retx_k_send_ = k; }
  void set_retx_k_recv(uint32_t k)   { retx_k_recv_ = k; }
  void set_retx_disabled(bool d)     { retx_disabled_.store(d); }
 private:

  void receive_one();               // legacy fallback (pump off)
  void process_datagram(const uint8_t* buf, ssize_t n);  // pump+sync entry
  void drain_pending_locked();      // requires rx_mu_ held
  void pump_loop();                 // runs on pump_thread_

  // Stage 3 helpers.
  void compute_missing_locked_();           // refresh nack_state_; rx_mu_ held
  void drain_nack_state_();                 // emit due NACKs; takes rx_mu_
  void send_nack_(uint32_t s, uint16_t i);  // header-only KIND_NACK datagram
  void handle_incoming_nack_(uint32_t s, uint16_t i);  // sender's NACK reply
  void resend_fragment_(uint32_t s, uint16_t i,
                        const TxRecord& rec); // KIND_DATA replay

  // Stage 4 helpers.
  void send_poison_(const std::string& reason);   // emits KIND_POISON; sets poisoned_
  void mark_poisoned_(const std::string& reason); // local-only; sets poisoned_, wakes recv_cv
  void throw_if_poisoned_();                      // throws ChannelPoisonedError if poisoned_
};

}  // namespace io
