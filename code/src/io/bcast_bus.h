#pragma once

#include <netinet/in.h>

#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <deque>
#include <map>
#include <mutex>
#include <set>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace net { class TDMAScheduler; }

namespace io {

class ChannelPoisonedError : public std::runtime_error {
 public:
  explicit ChannelPoisonedError(const std::string& msg)
      : std::runtime_error(msg) {}
};

// One broadcast bus per host. One UDP socket bound to (192.168.1.X,
// port). One pump thread. Per-(target) send state, per-(sender) recv
// state. Always TDMA-aligned, always broadcast, always per-pair AES.
class BcastBus {
 public:
  static constexpr size_t MAX_PAYLOAD = 1400;
  static constexpr size_t HEADER_SIZE = 20;
  static constexpr uint32_t SYNC_MAGIC = 0xBEEFCAFEu;

  static constexpr uint32_t KIND_DATA   = 0;
  static constexpr uint32_t KIND_NACK   = 1;
  static constexpr uint32_t KIND_POISON = 2;
  static constexpr uint32_t KIND_SYNC   = 3;

  // Bind one socket on (INADDR_ANY, port). `ips` has size nP and is
  // indexed by party_id; ips[self_id] is our own TSN IP (used for
  // self-loopback drop), ips[other] is used for the sender-side NACK
  // origin check (Stage C). Derive K_{self, t} from the seed for
  // every t in [0, nP).
  BcastBus(int self_id, int nP, int port,
           const std::vector<std::string>& ips,
           net::TDMAScheduler* scheduler,
           uint64_t key_seed);
  ~BcastBus();

  BcastBus(const BcastBus&) = delete;
  BcastBus& operator=(const BcastBus&) = delete;

  void set_retx_k_send(uint32_t k) { retx_k_send_ = k; }
  void set_retx_k_recv(uint32_t k) { retx_k_recv_ = k; }

  // Cluster sync: broadcast SYNC frames carrying self_id; block until
  // one SYNC has arrived from every other party.
  void sync();

  // Spawn the recv pump. Must be called after sync().
  void start_pump();

  // Protocol API. Encrypts payload, fragments, sendto broadcast.
  // Throws ChannelPoisonedError on cap exhaustion for (self, dst).
  void send(int dst, const void* data, size_t len);

  // Block until len bytes from `src` are queued, then memcpy out.
  // Throws ChannelPoisonedError if the (src, self) pipe is poisoned.
  void recv(int src, void* data, size_t len);

  // Sum of bytes ever sent across all targets (matches legacy
  // NetIOMP::count() semantics).
  int64_t app_bytes_sent() const;
  void reset_stats();

  // Per-target bytes sent (matches legacy `network.get(i, ...)->counter`
  // accessor for benchmark's CommPoint). Out-of-range or self-target
  // returns 0.
  uint64_t bytes_sent_to(int target) const;

 private:
  struct Partial {
    uint32_t frag_total = 0;
    uint32_t received = 0;
    std::vector<std::vector<uint8_t>> frags;
  };
  struct Chunk {
    std::vector<uint8_t> bytes;
    size_t offset = 0;
  };
  struct TxRecord {
    uint16_t frag_total = 0;
    uint32_t payload_len = 0;
    std::vector<uint8_t> payload;   // exact bytes that egressed
    uint32_t nack_count = 0;
  };
  struct NackRec {
    uint32_t attempts = 0;
    uint64_t last_nack_ns = 0;
  };

  static constexpr size_t TX_BUF_CAP_STREAMS = 4096;
  struct TxState {
    uint32_t local_seq = 0;
    uint8_t  pair_key[16] = {};
    std::map<std::pair<uint32_t, uint16_t>, TxRecord> tx_buf;
    std::deque<uint32_t> tx_buf_order;
    // Streams whose fragments are still being inserted into tx_buf
    // by the calling thread's send(). A NACK for a fragment of a
    // seq in this set is "in-flight, not yet inserted" — must not
    // be classified as evicted/POISON. Erased when send() finishes
    // emitting all fragments of that seq.
    std::set<uint32_t> streams_in_flight;
    std::mutex mu;
    uint64_t app_bytes = 0;
    uint64_t datagrams_tx = 0;
    uint64_t tx_buf_evictions = 0;
    uint64_t retx_sends = 0;
    std::atomic<bool> poisoned{false};
  };
  std::vector<TxState> tx_;        // size nP, indexed by target_id

  struct RxState {
    uint32_t next_rx_seq = 0;
    uint32_t max_seen_seq = 0;
    bool     any_seen = false;
    std::map<uint32_t, Partial> pending;
    std::deque<Chunk> rx;
    size_t   rx_bytes = 0;
    std::map<std::pair<uint32_t, uint16_t>, NackRec> nack_state;
    std::mutex mu;
    std::condition_variable cv;
    uint64_t datagrams_rx = 0;
    std::atomic<bool> poisoned{false};
  };
  std::vector<RxState> rx_;        // size nP, indexed by sender_id

  // Witness state: per-(sender, target) where sender != self AND
  // target != self. Witness only tracks seqs (no payload, no decrypt)
  // and emits one-shot NACKs for missing seqs. (Stage C.)
  struct WitnessState {
    std::set<uint32_t> seen;       // seqs we've witnessed
    std::set<uint32_t> nacked;     // seqs we've already NACKed once
    uint32_t max_seen = 0;
    uint32_t low_walk = 0;          // lower bound for the gap-walk
    bool     any_seen = false;
    std::mutex mu;
  };
  // Flat vector of size nP*nP, indexed by sender*nP + target. Entries
  // where sender == self_id or target == self_id are unused.
  std::vector<WitnessState> witness_;

  // Party_id → IP address (network byte order). Used for the
  // sender-side NACK origin check: a NACK is acted on only if its
  // source IP matches ip_table_[missing_target_id].
  std::vector<uint32_t> ip_table_;

  int sock_ = -1;
  uint8_t self_id_;
  int     nP_;
  int     port_;
  uint32_t self_tsn_ip_be_ = 0;
  sockaddr_in bcast_addr_{};
  net::TDMAScheduler* scheduler_;
  uint32_t retx_k_send_ = 5;
  uint32_t retx_k_recv_ = 5;
  uint64_t cycle_ns_ = 100'000'000;

  std::thread pump_thread_;
  std::atomic<bool> pump_stop_{false};
  std::atomic<bool> pump_running_{false};

  uint64_t dropped_self_ = 0;
  uint64_t witness_dispatched_ = 0;       // Stage C: frames routed to witness
  uint64_t dropped_unknown_ = 0;
  uint64_t witness_nacks_sent_ = 0;
  uint64_t target_nacks_sent_ = 0;
  uint64_t nack_origin_dropped_ = 0;      // NACKs dropped because of origin check
  uint64_t nack_received_total_ = 0;      // every handle_nack_ entry (diagnostics)

  void pump_loop_();
  void handle_data_(uint8_t* buf, ssize_t n);
  void handle_nack_(uint8_t* buf, ssize_t n, const sockaddr_in& src);
  void handle_poison_(uint8_t* buf, ssize_t n);
  void drain_pending_locked_(RxState& rs);
  void compute_missing_locked_(RxState& rs);
  void drain_nack_state_(uint8_t sender);

  // Stage C: witness state update + drain.
  void witness_observe_(uint8_t sender, uint8_t target, uint32_t seq);
  void witness_drain_(uint8_t sender, uint8_t target);

  // 32-byte NACK frame (20 hdr + 12 body). missing_sender = whose
  // stream has the gap (becomes hdr_target so the original sender
  // routes it). missing_target = the intended recipient (used by
  // the sender's origin check). Used by both target NACKs (where
  // missing_target == self_id) and witness NACKs (otherwise).
  void send_nack_(uint8_t missing_sender, uint8_t missing_target,
                  uint32_t seq, uint16_t idx);
  void send_poison_to_target_(uint8_t target, const std::string& reason);
  void resend_fragment_(uint8_t target, uint32_t seq, uint16_t idx,
                        const TxRecord& rec);

  void mark_recv_poisoned_(uint8_t sender, const std::string& reason);
  void throw_if_recv_poisoned_(uint8_t sender);
  void mark_send_poisoned_(uint8_t target, const std::string& reason);
  void throw_if_send_poisoned_(uint8_t target);
};

}  // namespace io
