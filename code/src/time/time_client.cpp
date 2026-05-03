#include "time_source.h"

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <stdexcept>
#include <thread>

namespace timesrc {

TimeSource::TimeSource() {
  fd_ = shm_open(SHM_NAME, O_RDONLY, 0);
  if (fd_ < 0) return;
  void* p = mmap(nullptr, sizeof(TimeSrcShared), PROT_READ, MAP_SHARED, fd_, 0);
  if (p == MAP_FAILED) {
    close(fd_);
    fd_ = -1;
    return;
  }
  shm_ = static_cast<TimeSrcShared*>(p);
  if (shm_->magic != SHM_MAGIC || shm_->version != SHM_VERSION) {
    munmap(shm_, sizeof(TimeSrcShared));
    close(fd_);
    shm_ = nullptr;
    fd_ = -1;
  }
}

TimeSource::~TimeSource() {
  if (shm_) munmap(shm_, sizeof(TimeSrcShared));
  if (fd_ >= 0) close(fd_);
}

uint64_t TimeSource::now_ns() const {
  if (!shm_) return mono_raw_ns();
  // Seqlock read with bounded retry.
  for (int i = 0; i < 8; ++i) {
    uint64_t s1 = shm_->seq.load(std::memory_order_acquire);
    if (s1 & 1ULL) { std::this_thread::yield(); continue; }
    uint64_t epoch = shm_->epoch_ns;
    uint64_t mono = shm_->local_mono_ns;
    uint64_t s2 = shm_->seq.load(std::memory_order_acquire);
    if (s1 == s2) {
      // Extrapolate: shared-epoch advances 1:1 with local monotonic.
      uint64_t now_mono = mono_raw_ns();
      return epoch + (now_mono - mono);
    }
  }
  return mono_raw_ns();
}

uint32_t TimeSource::quality_ns() const {
  return shm_ ? shm_->quality_ns : UINT32_MAX;
}

uint32_t TimeSource::backend() const {
  return shm_ ? shm_->backend_id : BACKEND_UNKNOWN;
}

std::string TimeSource::backend_name() const {
  switch (backend()) {
    case BACKEND_FAKE: return "fake";
    case BACKEND_NTP:  return "ntp";
    case BACKEND_PTP:  return "ptp";
    default:           return "unknown";
  }
}

}  // namespace timesrc
