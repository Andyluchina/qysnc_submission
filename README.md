# qsync — Artifacts

Bundle accompanying the qsync paper. A maliciously-secure MPC system
that runs over a synchronized network: TDMA over UDP broadcast on top
of a PTP-synced clock, optionally enforced by a TSN switch's Qbv
gate-control list.

## Layout

```
code/      C++ source + build (see code/README.md)
scripts/   network config (taprio, tsn_switch), sweep drivers, plot scripts
results/   raw measurement data (TSVs + per-party logs)
graphs/    paper figures
```

## Results and figures

Raw measurement data is in `results/`; the corresponding paper figures
are in `graphs/`. Each figure has a matching plot script in
`scripts/plotting/`:

| Figure | Plot script | Source data |
|--------|-------------|-------------|
| `darkpool_size_sweep_latency.png` | `plot_darkpool_size.py` | `results/darkpool_size_sweep_n3_tsn/` |
| `e1_throughput_vs_n.png` | `plot_e1_throughput_v2.py` | `results/e1_n_sweep_eno1/` |
| `e1_time_vs_n.png` | `plot_e1_time_v2.py` | `results/e1_n_sweep_eno1/` |
| `motivation_v2.png` | `plot_motivation_v2.py` | `results/motivation_v2/` |
| `slot_gate_sweep_throughput.png` | `plot_slot_gate_sweep_v2.py` | `results/slot_sweep_n4/` |

## Build & run

See [code/README.md](code/README.md). Hostnames and IPs throughout the
bundle are generic placeholders (`coord`, `server1`–`server6`).
