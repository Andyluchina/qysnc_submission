# qsync

A multi-party computation (MPC) system that runs over a synchronized
network. Parties exchange shares of secret data, evaluate an arithmetic
circuit together, and reconstruct only the final output — no party
ever learns another party's input.

## What's in here

```
qsync-ae/
├── code/                       MPC source + build
│   ├── src/
│   │   ├── asterisk/           Maliciously-secure MPC protocol
│   │   ├── assistedMPC/        Trusted-dealer MPC variant
│   │   ├── net/                Software TDMA scheduler
│   │   ├── io/                 Reliable broadcast bus (UDP + AES-CTR)
│   │   ├── time/               Time client (PTP-backed slot clock)
│   │   └── utils/              Circuit, share types, helpers
│   └── benchmark/              Application benchmarks (darkpool, etc.)
├── scripts/
│   ├── taprio/                 Host-side taprio (Linux qdisc) install
│   ├── tsn_switch/             Switch-side Qbv + port→TC classifier config
│   ├── sweeps_tsn/             Sweeps over hardware TSN (switch-enforced)
│   ├── sweeps_software_tdma/   Sweeps over software TDMA (taprio + scheduler)
│   ├── fault_tolerance/        Crash, blacklist, and flood experiments
│   ├── plotting/               Aggregation + figure scripts
│   └── net_configs/            Per-N host-list JSONs
└── results/                    Output directory
```

Unchanged
```
(byte-identical to code_host/src/): src/asterisk/, src/assistedMPC/, src/utils/, and most of benchmark/.
```

New (qsync-only):
```
 src/io/bcast_bus.{h,cpp}, src/io/aes_ctr.h, src/io/_legacy/, src/net/tdma_scheduler.{h,cpp}, src/time/, plus a full rewrite of src/io/netmp.h.
```
## How it works at a glance

- **Circuit evaluation.** The protocol takes an arithmetic circuit
  (`utils/circuit`), splits each input into authenticated additive
  shares (`AuthAddShare` in `asterisk/sharing.h`), evaluates gate by
  gate, and at the end runs a MAC check
  (`OnlineEvaluator::MACVerification`) that aborts if any party
  cheated.
- **Time-sliced sending.** Every outbound datagram passes through a
  TDMA gate (`net/tdma_scheduler`) that pins the party to its assigned
  slot in a repeating cycle, so traffic doesn't collide on the wire.
- **Reliable broadcast.** All party-to-party messages go over a single
  encrypted UDP broadcast bus (`io/bcast_bus`) with sequence numbers,
  NACK-driven retransmission, third-party witness NACKs, and per-pipe
  poisoning that quarantines a peer once it stops responding or sends
  unauthenticated frames.

## Build and run

```bash
cd code
./setup_and_build.sh                  # builds into ./build
./run_native.sh                       # single-host smoke test
```

To run on a cluster, point each host at a `net_config` JSON from
`scripts/net_configs/` and launch the same binary on every party.

## Network setup

Both modes share the same software stack: PTP-synced clocks, the Linux
`taprio` qdisc on the outbound NIC, and the application-level
`TDMAScheduler` (`src/net/tdma_scheduler.h`) that gates every datagram
before it hits the socket. They differ only in where the schedule is
*enforced*:

- **Software TDMA** — runs over a regular L2 switch on `eno1`. taprio
  is installed by `scripts/taprio/install_taprio_pat.sh`. Slot
  discipline is host-side only; nothing in the network drops
  out-of-slot packets.
- **Hardware TSN** — runs over a TSN-capable switch on `eno2`. taprio
  is installed on each host by `scripts/taprio/setup_eno2_aligned.sh`,
  with its `base-time` aligned to the switch's Qbv reference. The
  switch's own gate-control list, ingress port→TC classifier, and
  Byzantine-port containment are configured by
  `scripts/tsn_switch/switch_qbv_tdma.cfg` (paste into the switch CLI
  in `system-view`); the switch enforces the schedule by dropping
  anything that arrives outside the owner's slot, so hosts must stay
  in their slot.

Both require a shared time source: `timesrcd` runs on every host and
reads the eno1 or eno2 PHC respectively. UDP ports 10000–10100 must be
open on every host; firewall rules for TCP do not cover UDP.

## Output

Sweeps write into `results/<experiment_name>/`:

- `summary.tsv` — one row per cell (status, timing, throughput)
- `per_party.tsv` — per-party breakdowns
- `progress.log` — sweep driver log
- per-cell subdirectories with `launcher.log` and `partyN.log`

Software-TDMA runs additionally emit `timesrcd_local.log`. A party that
logs `TDMAScheduler: no TimeSource; scheduling disabled` has fallen
out of slot-pacing and that cell should be re-run.
