# qsync — Artifact Evaluation

Artifact-evaluation view of the qsync evaluation: the latest MPC source
under test, plus the scripts used to configure the network, run the
sweeps (hardware TSN and software TDMA), drive the fault-tolerance
experiments, and produce the figures in the paper.

Files here are symlinked from the canonical working directories;
editing the targets updates the originals.

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