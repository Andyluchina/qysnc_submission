#pragma once

#include <atomic>
#include <cstdint>
#include <ctime>
#include <string>

namespace timesrc {

// Shared memory layout used by `timesrcd` (writer) and clients (readers).
// POSIX shm object name is fixed; path exposed as /dev/shm/<SHM_NAME>.
constexpr const char* SHM_NAME = "timesrc";
constexpr uint32_t SHM_MAGIC = 0x54535243;  // 'TSRC'
constexpr uint32_t SHM_VERSION = 1;

enum BackendId : uint32_t {
  BACKEND_UNKNOWN = 0,
  BACKEND_FAKE    = 1,
  BACKEND_NTP     = 2,
  BACKEND_PTP     = 3,
};

// Seqlock-style shared structure. Writer increments seq to odd, writes
// fields, then increments to even. Readers read seq, fields, seq again;
// retry if seq changed or was odd.
struct TimeSrcShared {
  uint32_t magic;        // SHM_MAGIC
  uint32_t version;      // SHM_VERSION
  uint32_t backend_id;   // BackendId
  uint32_t quality_ns;   // estimated sync error
  std::atomic<uint64_t> seq;
  uint64_t epoch_ns;     // shared-clock ns at sample
  uint64_t local_mono_ns; // CLOCK_MONOTONIC_RAW at sample
  uint64_t _reserved[6];
};
static_assert(sizeof(TimeSrcShared) <= 128, "TimeSrcShared too large");

inline uint64_t mono_raw_ns() {
  timespec ts{};
  clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
  return static_cast<uint64_t>(ts.tv_sec) * 1'000'000'000ULL +
         static_cast<uint64_t>(ts.tv_nsec);
}

// Client-side handle. Maps the shm object created by timesrcd.
class TimeSource {
 public:
  TimeSource();
  ~TimeSource();
  TimeSource(const TimeSource&) = delete;
  TimeSource& operator=(const TimeSource&) = delete;

  bool ok() const { return shm_ != nullptr; }
  uint64_t now_ns() const;
  uint32_t quality_ns() const;
  uint32_t backend() const;
  std::string backend_name() const;

 private:
  TimeSrcShared* shm_{nullptr};
  int fd_{-1};
};

}  // namespace timesrc
