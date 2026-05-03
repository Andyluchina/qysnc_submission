# qsync — Artifact Evaluation

Artifact-evaluation view of the qsync evaluation: the latest MPC source.

Accountability & Reliable Broadcast
The accountability layer lives entirely in the broadcast bus (code/src/io/bcast_bus.h, code/src/io/bcast_bus.cpp)

## Layout

```
qsync-ae/
├── code/                    Latest MPC source + build (symlinks)
├── scripts/
│   ├── taprio/              TSN taprio / GCL configuration
│   ├── sweeps_tsn/          Sweeps over hardware TSN (eno2, taprio)
│   ├── sweeps_software_tdma/ Sweeps over software TDMA (qsync)
│   ├── fault_tolerance/     Crash, blacklist, and flood resilience
│   ├── plotting/            Aggregation + figure scripts
│   └── net_configs/         Per-N net_config JSONs (TSN and non-TSN)
└── results/                 Output dir (sweeps write here by default)
```