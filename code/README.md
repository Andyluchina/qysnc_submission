# Asterisk MPC — Native Distributed Setup

Runs Asterisk MPC across 5 physical machines at UPenn CIS without Docker.

## Party layout (n=4)

| Party | Role | Machine | IP |
|-------|------|---------|-----|
| 0 | Dealer | local | 158.130.54.27 |
| 1 | Compute | ds15.seas.upenn.edu | 158.130.54.122 |
| 2 | Compute | ds16.seas.upenn.edu | 158.130.54.133 |
| 3 | Compute | ds17.seas.upenn.edu | 158.130.54.19 |
| 4 | Compute | ds18.seas.upenn.edu | 158.130.54.20 |

SSH access configured in `~/.ssh/config` with key `~/.ssh/ds_upenn`.

## Code locations on each machine

| Machine | Source tree | Compiled binary | Runtime libs | Notes |
|---------|-------------|-----------------|--------------|-------|
| **Local** | `/root/asterisk-native/` | `/root/asterisk-native/build/benchmarks/asterisk_mpc` | system (dnf-installed) | Fedora 34, glibc 2.33 |
| **ds15** | — | `/tmp/asterisk-native/build/benchmarks/asterisk_mpc` | `/tmp/asterisk-native/lib/` | `/root` is full — must use `/tmp` |
| **ds16** | `/tmp/asterisk-native/` | `/tmp/asterisk-native/build/benchmarks/asterisk_mpc` | `/tmp/asterisk-native/lib/` | **Build machine** — NTL/emp-tool/json installed here from source |
| **ds17** | — | `/tmp/asterisk-native/build/benchmarks/asterisk_mpc` | `/tmp/asterisk-native/lib/` | Fedora 35 (matches ds16 glibc) |
| **ds18** | — | `/tmp/asterisk-native/build/benchmarks/asterisk_mpc` | `/tmp/asterisk-native/lib/` | Fedora 35 (matches ds16 glibc) |

**Key detail:** Local machine is Fedora 34 (glibc 2.33), DS machines are Fedora 35 (glibc 2.34). This means there are **two binaries** built separately:

- `local-built binary` — runs on the local host only
- `ds16-built binary` — runs on all 4 DS machines (ds15/16/17/18 all have the same glibc)

## Shared config

- **Net config** (party IP list): `/tmp/asterisk_bundle/net_config.json` on all machines
  ```json
  ["158.130.54.27","158.130.54.122","158.130.54.133","158.130.54.19","158.130.54.20"]
  ```
- **Firewall**: TCP + UDP ports 10000–10100 open on all 5 machines (MPC traffic; UDP since the transport was moved to UDP+TDMA — see [TDMA_UDP_NOTES.md](TDMA_UDP_NOTES.md))

## Running

```bash
bash /root/asterisk-native/run_native.sh <gates_per_level> <depth> <repeat>
# e.g.
bash /root/asterisk-native/run_native.sh 500 50 1          # small circuit, 25K gates
bash /root/asterisk-native/run_native.sh 10000 100 1       # 1M gates, standard benchmark
```

Results land in `/root/asterisk-native/results/partyN.log`.

The runner starts a `timesrcd` daemon (PTP-capable shared clock) on each
host before launching parties and kills it on exit. UDP + TDMA is the
default transport; see [TDMA_UDP_NOTES.md](TDMA_UDP_NOTES.md) for env
vars (`TIMESRC_BACKEND`, `TDMA_SLOT_NS`, `TDMA_DISABLED`, etc.).

## Modifying the code & recompiling

The canonical source tree is `/root/asterisk-native/` on the local machine. Edit files under `src/` (protocol implementation) or `benchmark/` (drivers) there, then:

### Step 1 — Rebuild locally (for party 0)

```bash
cd /root/asterisk-native/build
make -j$(nproc) asterisk_mpc
```

The resulting binary at `/root/asterisk-native/build/benchmarks/asterisk_mpc` runs as party 0 (local).

### Step 2 — Push source changes to ds16 and rebuild

ds16 is the "build server" for DS machines. Sync changes there:

```bash
rsync -az --exclude='build' /root/asterisk-native/{src,benchmark,CMakeLists.txt,cmake} ds16:/tmp/asterisk-native/
ssh ds16 'cd /tmp/asterisk-native/build && make -j$(nproc) asterisk_mpc'
```

### Step 3 — Distribute the ds16 binary to ds15/ds17/ds18

After ds16 finishes building, copy the new binary out:

```bash
for h in ds15 ds17 ds18; do
    scp ds16:/tmp/asterisk-native/build/benchmarks/asterisk_mpc $h:/tmp/asterisk-native/build/benchmarks/asterisk_mpc
done
```

### Step 4 — Run again

```bash
bash /root/asterisk-native/run_native.sh 500 50 1
```

## Dependencies

Installed once per machine (already done on all 5). Full install commands live in `setup_and_build.sh`.

**Local machine (Fedora 34):**
- System packages (dnf): `gcc-c++ cmake gmp-devel openssl-devel boost-devel ntl-devel`
- From source to `/usr/local/`: `nlohmann/json v3.11.3`, `emp-tool` (latest)

**ds16 (Fedora 35, build server):**
- System packages (dnf): same as above except `ntl-devel` not in repo, built from source
- From source to `/usr/local/`: `NTL 11.5.1`, `nlohmann/json v3.11.3`, `emp-tool`

**ds15, ds17, ds18 (Fedora 35):**
- System packages (dnf): `boost-devel` (needed for runtime libs `libboost_program_options.so.1.76.0`, etc.)
- The `libntl.so.44` and `libemp-tool.so` are copied from ds16 into `/tmp/asterisk-native/lib/`

## From-scratch setup on a new Fedora machine

```bash
rsync -az --exclude='build' /root/asterisk-native/ <new-host>:/tmp/asterisk-native/
ssh <new-host> 'bash /tmp/asterisk-native/setup_and_build.sh'
# Make sure TCP ports 10000-10100 are open
ssh <new-host> 'firewall-cmd --add-port=10000-10100/tcp --permanent && firewall-cmd --reload'
```

## Troubleshooting

**`GLIBC_2.34 not found`** — You tried to run a ds16-built binary on a Fedora 34 machine. Rebuild on that machine's own glibc.

**`Connection refused` on MPC ports** — Firewall blocking 10000–10100. Run `firewall-cmd --add-port=10000-10100/tcp --permanent && firewall-cmd --add-port=10000-10100/udp --permanent && firewall-cmd --reload`.

**Party 0 hangs at startup** — Party 0 connects to higher-PID parties, so those must be listening first. The runner already launches in reverse order (4→3→2→1→0) with small delays.

**No space on device (ds15)** — ds15's `/` is 100% full. Never write to `/root` on ds15; `/tmp` is tmpfs with 32 GB free.
