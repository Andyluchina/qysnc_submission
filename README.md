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

## Quick start

```bash
# 1. Build
cd code
./setup_and_build.sh                 # builds into ./build

# 2. Configure TSN on the wire (run on every host that uses eno2)
sudo ../scripts/taprio/install_taprio_ds15pat.sh         # 1 ms slot, ds15-pattern GCL

# 3. Sanity check
./run_native.sh                       # single-cell run

# 4. Reproduce a paper figure
../scripts/sweeps_tsn/run_darkpool_size_sweep_tsn.sh     # main TSN size sweep
../scripts/plotting/plot_darkpool_size_tsn.py            # produces the figure
```

## Reproduction map (paper figure → script)

| Section / Figure                       | Sweep script                                                  | Plot script                            |
|----------------------------------------|---------------------------------------------------------------|----------------------------------------|
| Darkpool size sweep (TSN, CDA + VM)    | `scripts/sweeps_tsn/run_darkpool_size_sweep_tsn.sh`           | `scripts/plotting/plot_darkpool_size_tsn.py` |
| Darkpool size sweep (non-TSN, v3)      | (in `e1_sweep/run_darkpool_size_sweep_v3.sh`)                 | `scripts/plotting/plot_darkpool_size_v3.py`  |
| E1 throughput vs N                     | `scripts/sweeps_tsn/run_e1_n_sweep.sh`                        | (in `e1_sweep/`)                       |
| Software-TDMA (qsync) sweep            | `scripts/sweeps_software_tdma/run_qsync_only_sweep.sh`        | `scripts/plotting/plot_darkpool_size_tsn.py` |
| Slot-size sweep                        | `scripts/sweeps_software_tdma/run_slot_sweep_clean.sh`        | (in `e1_sweep/`)                       |
| Crash recovery (τ=4)                   | `scripts/fault_tolerance/crash_tau4_v2.sh`                    | `scripts/plotting/plot_recovery.py`    |
| Blacklist (τ=20)                       | `scripts/fault_tolerance/blacklist_tau20.sh`                  | `scripts/plotting/plot_recovery.py`    |
| Flood / DoS resilience                 | `scripts/fault_tolerance/run_flood_sweep.sh`                  | (sibling `plot_flood_sweep.py`)        |

## Hosts and network

Experiments run on `ds15`–`ds17` plus a local coordinator. Two NICs are
used per host: `eno1` for non-TSN (control + non-TSN baselines) and
`eno2` for the TSN island. PTP runs on `eno2` (`/dev/ptp1`). Net-config
JSONs in `scripts/net_configs/` enumerate the per-N host lists.

**UDP firewall reminder:** `firewalld` rules for TCP do not imply UDP;
ports 10000–10100/UDP must be opened explicitly on every cluster host or
qsync runs will silently stall.

## Notes for AE reviewers

- All numerical results in the paper come from re-runs on the physical
  cluster; figure scripts admit only `status=ok` rows from the
  per-sweep `summary.tsv`.
- Sweeps write into `results/<experiment_name>/` as
  `summary.tsv`, `per_party.tsv`, `progress.log`, plus per-cell
  subdirectories with `launcher.log` and `partyN.log` for each party.
- Software-TDMA runs additionally emit `timesrcd_local.log`; if any
  party logs `TDMAScheduler: no TimeSource; scheduling disabled`,
  that party fell out of slot-pacing and the cell should be re-run.
