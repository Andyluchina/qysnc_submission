#include "tdma_scheduler.h"

#include <cstdio>
#include <cstdlib>
#include <chrono>
#include <fstream>
#include <sstream>
#include <thread>

#include <nlohmann/json.hpp>

#include "../time/time_source.h"

namespace net {

TDMASchedule TDMASchedule::round_robin(int nP, uint64_t slot_ns) {
  TDMASchedule s;
  s.slot_ns = slot_ns;
  s.slot_owners.resize(nP);
  for (int i = 0; i < nP; ++i) s.slot_owners[i] = {i};
  return s;
}

TDMASchedule TDMASchedule::from_json_file(const std::string& path) {
  TDMASchedule s;
  std::ifstream f(path);
  if (!f) {
    std::fprintf(stderr, "TDMASchedule: cannot open %s\n", path.c_str());
    return s;
  }
  nlohmann::json j;
  f >> j;
  s.slot_ns = j.value("slot_ns", uint64_t{10'000'000});
  for (const auto& row : j.at("schedule")) {
    std::vector<int> owners;
    for (const auto& p : row) owners.push_back(p.get<int>());
    s.slot_owners.push_back(std::move(owners));
  }
  return s;
}

TDMAScheduler::TDMAScheduler(int party, timesrc::TimeSource* ts,
                             TDMASchedule sched, bool disabled)
    : party_(party), ts_(ts), sched_(std::move(sched)), disabled_(disabled) {
  if (!sched_.ok()) {
    disabled_ = true;
    return;
  }
  owns_.assign(sched_.slot_owners.size(), false);
  for (size_t i = 0; i < sched_.slot_owners.size(); ++i) {
    for (int p : sched_.slot_owners[i]) {
      if (p == party_) { owns_[i] = true; break; }
    }
  }
  slot_hist_ = std::vector<std::atomic<uint64_t>>(sched_.slot_owners.size());
  if (!ts_ || !ts_->ok()) {
    std::fprintf(stderr, "TDMAScheduler: no TimeSource; scheduling disabled\n");
    disabled_ = true;
  }
}

TDMAScheduler::~TDMAScheduler() {
  if (disabled_) return;
  std::fprintf(stderr,
               "TDMAScheduler[p=%d]: slot_ns=%lu cycle_slots=%zu "
               "waits=%lu ns_waited=%lu "
               "sends={in=%lu out=%lu boundary_spans=%lu}\n",
               party_,
               (unsigned long)sched_.slot_ns,
               sched_.slot_owners.size(),
               (unsigned long)waits_.load(),
               (unsigned long)ns_waited_.load(),
               (unsigned long)in_slot_sends_.load(),
               (unsigned long)out_of_slot_sends_.load(),
               (unsigned long)boundary_spans_.load());
  std::fprintf(stderr, "TDMAScheduler[p=%d]: per-slot send counts:", party_);
  for (size_t i = 0; i < slot_hist_.size(); ++i) {
    std::fprintf(stderr, " slot%zu(%s)=%lu",
                 i, owns_[i] ? "own" : "oth",
                 (unsigned long)slot_hist_[i].load());
  }
  std::fprintf(stderr, "\n");
}

uint64_t TDMAScheduler::wait_and_mark_pre() {
  if (disabled_) return 0;
  wait_for_slot();
  return ts_->now_ns();
}

void TDMAScheduler::mark_post(uint64_t t_pre) {
  if (disabled_) return;
  const uint64_t t_post = ts_->now_ns();
  const uint32_t s_pre  = slot_of(t_pre);
  const uint32_t s_post = slot_of(t_post);
  slot_hist_[s_pre].fetch_add(1, std::memory_order_relaxed);
  const bool pre_ok  = owns_slot(s_pre);
  const bool post_ok = owns_slot(s_post);
  if (pre_ok && post_ok && s_pre == s_post) {
    in_slot_sends_.fetch_add(1, std::memory_order_relaxed);
  } else {
    out_of_slot_sends_.fetch_add(1, std::memory_order_relaxed);
    if (s_pre != s_post) {
      boundary_spans_.fetch_add(1, std::memory_order_relaxed);
    }
  }
}

void TDMAScheduler::wait_for_slot() {
  if (disabled_) return;

  const uint64_t slot = sched_.slot_ns;
  const uint64_t cycle = slot * sched_.slot_owners.size();
  // Guard band: if less than this much of the current slot remains,
  // skip to the next owned slot so a sendto+mark_post doesn't spill
  // past the slot boundary. Default 1 ms — chosen so a 10 ms slot has
  // ~9 ms of transmit window while staying spill-free under burst at
  // 1 M-gate load (0 violations observed on the cluster). Override
  // with TDMA_GUARD_NS for tighter/larger guards.
  static uint64_t guard_ns = [&]{
    if (const char* s = std::getenv("TDMA_GUARD_NS"))
      return std::strtoull(s, nullptr, 10);
    return 1'000'000ULL;  // 1 ms
  }();

  while (true) {
    uint64_t now = ts_->now_ns();
    uint64_t pos = now % cycle;
    uint32_t cur = static_cast<uint32_t>(pos / slot);
    uint64_t in_slot_pos = pos - uint64_t(cur) * slot;
    uint64_t remaining = slot - in_slot_pos;
    if (owns_slot(cur) && remaining > guard_ns) return;

    // Find the nanosecond offset of the next slot we own.
    uint64_t delta_ns = 0;
    for (size_t k = 1; k <= sched_.slot_owners.size(); ++k) {
      uint32_t s = static_cast<uint32_t>((cur + k) % sched_.slot_owners.size());
      if (owns_[s]) {
        uint64_t next_pos = (cur + k) * slot;
        delta_ns = next_pos - pos;
        break;
      }
    }
    if (delta_ns == 0) return;  // no owned slots; degenerate

    waits_.fetch_add(1, std::memory_order_relaxed);
    ns_waited_.fetch_add(delta_ns, std::memory_order_relaxed);
    std::this_thread::sleep_for(std::chrono::nanoseconds(delta_ns));
    // Loop re-checks (timer slack may land us slightly before the slot).
  }
}

}  // namespace net
