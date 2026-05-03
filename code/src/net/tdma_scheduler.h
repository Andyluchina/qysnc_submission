#pragma once

#include <atomic>
#include <cstdint>
#include <string>
#include <vector>

namespace timesrc { class TimeSource; }

namespace net {

// A single cycle of slots: each entry is the list of party IDs that are
// permitted to transmit in that slot. One-owner-per-slot is the default
// round-robin; multi-owner is expressible without a schema change.
struct TDMASchedule {
  uint64_t slot_ns = 10'000'000;  // 10 ms default
  std::vector<std::vector<int>> slot_owners;

  bool ok() const { return slot_ns > 0 && !slot_owners.empty(); }

  // Round-robin: slot i -> party i (cycle length = nP). Suitable default
  // for Phase 3 tests.
  static TDMASchedule round_robin(int nP, uint64_t slot_ns);

  // Parse from JSON file. Accepts:
  //   { "slot_ns": <int>, "schedule": [[<pid>, ...], ...] }
  static TDMASchedule from_json_file(const std::string& path);
};

// Transmit-side TDMA gate. Before each outbound datagram, callers invoke
// wait_for_slot(); it blocks until the shared clock is inside one of
// this party's owned slots. If the scheduler is disabled or the shared
// clock is unavailable, it returns immediately (no-op).
//
// The RX path is unaffected — UDP datagrams received outside of our
// slot are still queued by the socket buffer and drained on recv_data.
class TDMAScheduler {
 public:
  TDMAScheduler(int party, timesrc::TimeSource* ts, TDMASchedule sched,
                bool disabled);
  ~TDMAScheduler();

  // Blocks until the calling thread may transmit, then returns the
  // shared-clock time (ns) at which it unblocked. Pass that value
  // back into mark_post() after sendto() completes so the scheduler
  // can verify the datagram both started and finished inside an
  // owned slot.
  uint64_t wait_and_mark_pre();

  // Record the outcome of a send that started at t_pre. Reads the
  // shared clock now; if t_pre and t_post are both in slots we own
  // AND the same slot, counts as in-slot. Otherwise counts as a
  // violation with a reason.
  void mark_post(uint64_t t_pre);

  // Disabled-bypass path: keep the old name alive so recv-side call
  // sites remain simple when the scheduler is off.
  void wait_for_slot();

  // Stats (atomic reads).
  uint64_t slot_waits() const { return waits_.load(); }
  uint64_t ns_waited()  const { return ns_waited_.load(); }
  uint64_t in_slot_sends() const { return in_slot_sends_.load(); }
  uint64_t out_of_slot_sends() const { return out_of_slot_sends_.load(); }
  uint64_t boundary_spans() const { return boundary_spans_.load(); }
  uint64_t slot_histogram(uint32_t slot_idx) const {
    return slot_idx < slot_hist_.size()
        ? slot_hist_[slot_idx].load() : 0ULL;
  }

  bool disabled() const { return disabled_; }
  uint64_t slot_ns() const { return sched_.slot_ns; }
  size_t cycle_slots() const { return sched_.slot_owners.size(); }

 private:
  int party_;
  timesrc::TimeSource* ts_;
  TDMASchedule sched_;
  bool disabled_;
  std::vector<bool> owns_;  // owns_[slot_idx] = party_ in slot_owners[s]

  std::atomic<uint64_t> waits_{0};
  std::atomic<uint64_t> ns_waited_{0};
  std::atomic<uint64_t> in_slot_sends_{0};
  std::atomic<uint64_t> out_of_slot_sends_{0};
  std::atomic<uint64_t> boundary_spans_{0};
  // Count of sends per cycle slot — useful to confirm that every
  // recorded send landed in slots this party owns (others should be 0).
  std::vector<std::atomic<uint64_t>> slot_hist_;

  bool owns_slot(uint32_t slot_idx) const {
    return slot_idx < owns_.size() && owns_[slot_idx];
  }

  uint32_t slot_of(uint64_t t_ns) const {
    const uint64_t cycle = sched_.slot_ns * sched_.slot_owners.size();
    return static_cast<uint32_t>((t_ns % cycle) / sched_.slot_ns);
  }
};

}  // namespace net
