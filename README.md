# arakyd

[![ci](https://github.com/malahmen/arakyd/actions/workflows/ci.yml/badge.svg)](https://github.com/malahmen/arakyd/actions/workflows/ci.yml)

> Arakyd Industries built the probe droids. One sits somewhere remote, takes
> readings, and transmits them home.

**The readings `node_exporter` cannot take, for an AMD Strix Halo host.**

This is not a metrics agent. `node_exporter` already covers CPU, memory, disk,
network and raw hwmon, and rewriting any of that would be work for nothing.
arakyd collects the three things that need knowing *which machine this is*, and
writes them where `node_exporter` will serve them.

## Why it exists at all

**Unified memory is invisible.** On a Strix Halo APU there is no meaningful
dedicated VRAM — the iGPU allocates out of system RAM through GTT. On this host
that was **44 GiB of 62** when measured, while `node_exporter` reported 52 GiB "used" and
accounts for none of it. No stock dashboard knows to look. It is also the
number that decides whether a model loads, which makes it the single most
useful reading on the machine.

**Temperatures arrive unreadable.** `node_hwmon_temp_celsius` is keyed by a
chip path like `pci0000:00_0000:00:18_3`. Correct, and useless on a dashboard.
Turning that into "CPU" needs a two-hop PromQL join through
`node_hwmon_chip_names`, and the mapping from chip name to role — `k10temp` is
the CPU, `amdgpu` the iGPU, `cros_ec` the board controller — is this machine's
knowledge, not `node_exporter`'s. So it is applied once, here.

**amdgpu exposes more than heat.** Package power and shader clock are in hwmon
and are not surfaced usably. The power is amdgpu's `PPT` (package power
tracking), which on an APU is the whole package - CPU and GPU together - not
the iGPU alone.

## What it emits

| Metric | Notes |
| --- | --- |
| `arakyd_temperature_celsius{role,chip,device,sensor}` | `role` is one of `cpu`, `igpu`, `nvme`, `board`, `board_ec`, `nic`, `wifi`, `other`. `device` is what the chip is attached to (`0000:c2:00.0`, `nvme0`), so two chips with one name - two NVMe drives, two GPUs - are two series rather than one dropped |
| `arakyd_gpu_memory_bytes{card,device,pool,state}` | `pool` is `gtt` or `vram`; `state` is `used` or `total`. `card` is the DRM minor (`card1`), which can change across boots; `device` is the PCI address, which does not |
| `arakyd_gpu_power_watts{card,device}` | from `power1_average`: package power (PPT), CPU and GPU together on an APU |
| `arakyd_gpu_clock_hertz{card,device}` | from `freq1_input` |
| `arakyd_collector_success` | **1 or 0.** See below — this one earns its keep |
| `arakyd_collector_samples{section}` | samples the last run produced, for `temperatures` and `gpu` |
| `arakyd_collector_last_run_seconds` | Unix time of the last run. **The one that says the collector stopped:** see below |
| `arakyd_collector_hwmon_chips`, `arakyd_build_info` | |

A negative reading is written as one (`-0.500`). It used to come out as
`0.-500`, which node_exporter cannot parse - and one bad line drops the whole
file, `arakyd_collector_success` with it.

`arakyd_collector_success` exists because `up` is not enough. `up` tells you
the host was reachable. It does not tell you this collector ran. Without it,
"exporter up, collector silently failing" is indistinguishable from "nothing to
report" — and a dashboard that cannot tell those apart is the thing this whole
project is meant to avoid. It is 1 only when a temperature was read **and**,
wherever a GPU's memory files are present, a GPU reading too: one sensor used
to be enough, with every GPU reading gone.

**But `success` cannot see a collector that stopped.** It is written by the
collector, so it says how the last run went - and when there is no next run
(timer disabled, script removed, the unit failing before it starts, a hung
read), node_exporter keeps serving the last file, `success 1` and plausible
temperatures included, for as long as the file exists. What does change is its
age: `time() - arakyd_collector_last_run_seconds` grows. The timer runs every
30 s, so more than 90 is a stopped collector.

## Usage

```sh
./arakyd.sh --check                  # what it discovered, and the role it assigned
./arakyd.sh --print                  # the metrics, to stdout
./arakyd.sh --write ~/.local/state/arakyd    # DIR/arakyd.prom, atomically
```

Needs **no root**: everything it reads is world-readable sysfs. Writes are
atomic (temp file, then `mv`) because `node_exporter` parses the whole file on
scrape and a partial read is an error, not a gap.

| Variable | |
| --- | --- |
| `ARAKYD_SYSFS` | sysfs root, default `/sys`. The suite points this at a fabricated tree |

## Install (corelia — manually managed, on purpose)

corelia is **deliberately outside kuat's Ansible scope**, which is the server
only. So this is installed by hand and stays that way; the units below are the
declarative part.

```sh
install -Dm755 arakyd.sh ~/.local/bin/arakyd.sh
mkdir -p ~/.config/containers/systemd ~/.config/systemd/user ~/.local/state/arakyd
cp quadlet/arakyd-node-exporter.container ~/.config/containers/systemd/
cp quadlet/arakyd-collector.service quadlet/arakyd-collector.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now arakyd-collector.timer
systemctl --user start arakyd-node-exporter
loginctl enable-linger "$USER"        # survive logout

curl -s localhost:9100/metrics | grep '^arakyd_'
```

The container image tag is **pinned**. Bump it deliberately — a monitoring
agent that changes underneath you is one you cannot trust a graph from.

### If `arakyd_` metrics are missing but `node_` ones are there

```
level=error collector=textfile msg="failed to read textfile collector directory"
  path=/textfile err="open /textfile: permission denied"
```

Two separate causes, both handled in the shipped unit, both worth recognising
if you move the state directory:

- **SELinux.** The mount needs `,z`. The tell is that `ls -ld /textfile` works
  inside the container while `ls -l` fails — stat is allowed, open is not — and
  `podman inspect` shows `opts=[rbind]` with no `z`. There is no AVC in the
  audit log, because the denial is about the object's label rather than a rule.
- **The user namespace.** `/home/<user>` and `.local/state` are both `0700` on
  Fedora, and the image runs as `nobody(65534)`, which maps to a subuid that
  cannot traverse them. `UserNS=keep-id:uid=65534,gid=65534` maps *this* user
  onto that uid, so the container reads exactly what you can read — without
  overriding the image's user or hardcoding a uid.

Because the container reads what you can read, it is given only what it needs:
`/proc`, `/sys`, the textfile directory and udev's database. It used to mount
the whole root filesystem at `/host`, which put `~/.ssh` behind an
unauthenticated `:9100`; with the two mounts it serves the same metrics.

## Getting it into Grafana

Two files in `deploy/`, both of which belong in the **`manifests`** repository,
because Argo CD reconciles that and only that. Copying them across is a
deliberate step, not an oversight:

| File | Goes into |
| --- | --- |
| `deploy/alloy-scrape-hosts.alloy` | `apps/alloy.yaml`, inside the existing Alloy config block |
| `deploy/grafana-hosts-dashboard.json` | `apps/grafana.yaml`, under `dashboards: kuat:` |

Both are live: the dashboard is `kuat / Hosts` in `apps/grafana.yaml`, and its
panels are what this README's queries describe. A change here is copied across
by hand; the copy in `manifests` is the one Grafana loads.

### Both hosts on one dashboard, on purpose

If corelia's panels are empty while meksha's are full, the monitoring is fine
and corelia is off. If **both** are empty, the monitoring is broken. The
dashboard diagnoses itself. meksha runs node_exporter (kuat's `node_exporter`
role) but not arakyd's collector, so its `arakyd_*` panels are empty by design.

### What `up` can and cannot tell you

| State | Signal |
| --- | --- |
| Host powered off | `up == 0` |
| Host up, exporter not running | `up == 0` — **indistinguishable** from the above |
| Host up, exporter up, collector ran and read nothing | `up == 1` and `arakyd_collector_success == 0` |
| Host up, exporter up, collector **stopped** | `up == 1` and `time() - arakyd_collector_last_run_seconds > 90`; `success` still reads 1 |
| Scrape job removed or never applied | `absent(up{job="hosts"})` — a *monitoring* failure |

And the trap: **Mimir's default lookback is 5 minutes**, so an instant query
returns the last sample within that window. For ~5 minutes after a host dies, a
temperature gauge shows a perfectly plausible 47 °C. Gate value panels on `up`
rather than trusting an instant reading on a host that is allowed to be absent.

### Alerting

Do not treat the two hosts alike. meksha unreachable is an incident; corelia
unreachable is a desktop being off. The alert worth having on both is
`absent(up{job="hosts"})` — that is the one that catches the scrape job being
removed and nobody noticing. The other is the collector: `kuat / Hosts` alerts
when `arakyd_collector_success` is 0, or the file is more than 90 s old, on a
host whose exporter is up.

## Tests

```sh
tests/run-all.sh
```

**46 checks.** No network, no root, and no dependence on this machine's
hardware: the collector runs against a fabricated sysfs tree, which is the only
way to test something whose whole job is knowing about one particular machine.

The case the suite exists for most: **hwmon indices are not stable across
boots.** They follow device probe order, so `k10temp` can be `hwmon6` today and
`hwmon3` after a kernel update. A collector that reads `hwmon6` keeps working
until it silently reports the wifi chip's temperature as the CPU's. One check
builds the same hardware at different `hwmonN` numbers and asserts the output
is byte-identical.

CI lints with `shellcheck -S warning`, like every sibling repo. Without the
severity flag the build depends on which *style* checks the runner's shellcheck
happens to enable by default — 0.11.0 has SC2002 off, the Ubuntu runner's older
build has it on — so a clean local run did not mean a green CI run. The
versions step prints both, which is what makes that visible rather than
puzzling.

Two bugs the suite caught before this ever ran anywhere:

- `find -name 'hwmon*'` also matches the **parent** directory `class/hwmon`, so
  every chip count was one too high.
- `arakyd_collector_success` was derived from "did any output appear", but the
  `# HELP`/`# TYPE` headers always appear — so the metric whose only purpose is
  detecting a broken collector could never report one. It counts samples now.

## License

[MIT](LICENSE) © 2026 malahmen.
