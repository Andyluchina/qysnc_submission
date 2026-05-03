// MIT License
//
// Copyright (c) 2018 Xiao Wang (wangxiao@gmail.com)
//
// Adapted from https://github.com/emp-toolkit/emp-agmpc.
// Migrated to a single per-host BcastBus on top of UDP broadcast,
// matching the TSN tree's transport. Header grew from 16 → 20 bytes;
// per-pair AES-CTR encryption derived from MPC_PAIR_KEY_SEED.
//
// Knobs:
//   TDMA_DISABLED=1        skip scheduling entirely (substrate-overhead E2)
//   TDMA_SLOT_NS=<ns>      slot length (default 1_048_544 ns ≈ 1.048 ms)
//   TDMA_SCHEDULE=<path>   JSON schedule file (overrides defaults)
//   TDMA_RETX_K_SEND       sender-side retx cap (default 5)
//   TDMA_RETX_K_RECV       receiver-side retx cap (default 5)
//   MPC_PAIR_KEY_SEED      AES-CTR key seed (default 200)
//   MPC_BROADCAST_IP       broadcast dst IP (override the default for the
//                          interface chosen via MPC_NETWORK)

#pragma once

#include <emp-tool/emp-tool.h>

#include <arpa/inet.h>

#include <cstdlib>
#include <memory>
#include <string>
#include <vector>

#include "bcast_bus.h"
#include "../net/tdma_scheduler.h"
#include "../time/time_source.h"
#include "../utils/types.h"

namespace io {
using namespace emp;
using namespace common::utils;

class NetIOMP {
 public:
  int party;
  int nP;
  std::vector<bool> sent;

  std::unique_ptr<timesrc::TimeSource> time_source;
  std::unique_ptr<net::TDMAScheduler> scheduler;
  std::unique_ptr<BcastBus> bus;

  NetIOMP(int party, int nP, int port, char* IP[], bool localhost = false)
      : party(party), nP(nP), sent(nP, false) {
    // Optional TDMA scheduler. Constructed only if TDMA_DISABLED is unset.
    // BcastBus accepts a nullptr scheduler and degrades to no app-level
    // gating; the kernel taprio (when installed) is the only remaining
    // gate in that case.
    const bool tdma_disabled = std::getenv("TDMA_DISABLED") != nullptr;
    if (!tdma_disabled) {
      time_source = std::make_unique<timesrc::TimeSource>();
      net::TDMASchedule sched;
      if (const char* sched_path = std::getenv("TDMA_SCHEDULE")) {
        sched = net::TDMASchedule::from_json_file(sched_path);
      } else {
        // Default 1_048_544 ns ≈ 1.048 ms — matches setup_taprio_eno1.sh's
        // per-host slot (4 entries × 262_136 ns) and the TSN tree's
        // default. Override via TDMA_SLOT_NS for the slot-duration sweep.
        uint64_t slot_ns = 1'048'544ULL;
        if (const char* s = std::getenv("TDMA_SLOT_NS")) {
          slot_ns = std::strtoull(s, nullptr, 10);
        }
        sched = net::TDMASchedule::round_robin(nP, slot_ns);
      }
      scheduler = std::make_unique<net::TDMAScheduler>(
          party, time_source.get(), sched, /*disabled=*/false);
    }

    uint64_t key_seed = 200ULL;
    if (const char* s = std::getenv("MPC_PAIR_KEY_SEED")) {
      key_seed = std::strtoull(s, nullptr, 10);
    }

    // Build the per-party IP table for the BcastBus. ips[p] is party p's
    // public eno1 IP (used for self-loopback drop on p == self, and for
    // the NACK origin check on p != self).
    std::vector<std::string> ips(nP);
    if (!localhost && IP) {
      for (int p = 0; p < nP; ++p) {
        if (IP[p]) ips[p] = std::string(IP[p]);
      }
    }

    bus = std::make_unique<BcastBus>(party, nP, port, ips,
                                     scheduler ? scheduler.get() : nullptr,
                                     key_seed);

    if (const char* s = std::getenv("TDMA_RETX_K_SEND")) {
      bus->set_retx_k_send(static_cast<uint32_t>(std::strtoul(s, nullptr, 10)));
    }
    if (const char* s = std::getenv("TDMA_RETX_K_RECV")) {
      bus->set_retx_k_recv(static_cast<uint32_t>(std::strtoul(s, nullptr, 10)));
    }
  }

  int64_t count() {
    return bus ? bus->app_bytes_sent() : 0;
  }

  void resetStats() {
    if (bus) bus->reset_stats();
  }

  void send(int dst, const void* data, size_t len) {
    if (dst != -1 && dst != party) {
      bus->send(dst, data, len);
      sent[dst] = true;
    }
  }

  void send(int dst, const NTL::ZZ_p* data, size_t length) {
    std::vector<uint8_t> serialized(length);
    size_t num = (length + FIELDSIZE - 1) / FIELDSIZE;
    for (size_t i = 0; i < num; ++i) {
      NTL::BytesFromZZ(serialized.data() + i * FIELDSIZE,
                       NTL::conv<NTL::ZZ>(data[i]), FIELDSIZE);
    }
    send(dst, serialized.data(), serialized.size());
  }

  void sendRelative(int offset, const void* data, size_t len) {
    int dst = (party + offset) % nP;
    if (dst < 0) dst += nP;
    send(dst, data, len);
  }

  void sendBool(int dst, const bool* data, size_t len) {
    for (int i = 0; i < len;) {
      uint64_t tmp = 0;
      for (int j = 0; j < 64 && i < len; ++i, ++j) {
        if (data[i]) tmp |= (0x1ULL << j);
      }
      send(dst, &tmp, 8);
    }
  }

  void sendBoolRelative(int offset, const bool* data, size_t len) {
    int dst = (party + offset) % nP;
    if (dst < 0) dst += nP;
    sendBool(dst, data, len);
  }

  void recv(int src, void* data, size_t len) {
    if (src != -1 && src != party) {
      bus->recv(src, data, len);
    }
  }

  void recv(int dst, NTL::ZZ_p* data, size_t length) {
    std::vector<uint8_t> serialized(length);
    recv(dst, serialized.data(), serialized.size());
    size_t num = (length + FIELDSIZE - 1) / FIELDSIZE;
    for (size_t i = 0; i < num; ++i) {
      data[i] = NTL::conv<NTL::ZZ_p>(
          NTL::ZZFromBytes(serialized.data() + i * FIELDSIZE, FIELDSIZE));
    }
  }

  void recvRelative(int offset, void* data, size_t len) {
    int src = (party + offset) % nP;
    if (src < 0) src += nP;
    recv(src, data, len);
  }

  void recvBool(int src, bool* data, size_t len) {
    for (int i = 0; i < len;) {
      uint64_t tmp = 0;
      recv(src, &tmp, 8);
      for (int j = 63; j >= 0 && i < len; ++i, --j) {
        data[i] = (tmp & 0x1) == 0x1;
        tmp >>= 1;
      }
    }
  }

  void recvRelative(int offset, bool* data, size_t len) {
    int src = (party + offset) % nP;
    if (src < 0) src += nP;
    recvBool(src, data, len);
  }

  void flush(int /*idx*/ = -1) {
    // UDP has no stream buffering; send() already put bytes on the wire.
  }

  void sync() {
    bus->sync();
    bus->start_pump();
  }
};

}  // namespace io
