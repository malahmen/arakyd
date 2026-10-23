#!/usr/bin/env bash
# arakyd's collection, against a fabricated sysfs.
#
# Everything here runs against $ARAKYD_SYSFS pointing at a tree this suite
# builds, because the alternative is a test that only passes on one machine —
# and the whole point of this collector is that it knows about particular
# hardware, which a CI runner does not have.
#
# The case it exists for most: hwmon indices are NOT stable across boots. They
# follow device probe order, so k10temp can be hwmon6 today and hwmon3 after a
# kernel update. A collector that reads hwmon6 works until it silently reports
# the wifi chip's temperature as the CPU's.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARA="${ARAKYD:-${TEST_DIR}/../arakyd.sh}"
[[ -f "$ARA" ]] || { echo "arakyd.sh not found at $ARA" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
FAILS=0
ok()   { printf '  ok   - %s\n' "$1"; }
bad()  { printf '  FAIL - %s\n' "$1"; FAILS=$((FAILS + 1)); }
chk()  { if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1: got '$3', want '$2'"; fi; }
has()  { if grep -qxF "$2" <<<"$3"; then ok "$1"; else bad "$1: missing '$2'"; fi; }
hasnt(){ if grep -qF "$2" <<<"$3"; then bad "$1: found '$2' and should not have"; else ok "$1"; fi; }

# chip <root> <hwmonN> <name> [sensor:milli:label ...]
chip() {
    local root="$1" idx="$2" name="$3"; shift 3
    local d="$root/class/hwmon/$idx"
    mkdir -p "$d"; printf '%s\n' "$name" > "$d/name"
    local spec n milli lbl
    for spec in "$@"; do
        IFS=: read -r n milli lbl <<<"$spec"
        printf '%s\n' "$milli" > "$d/temp${n}_input"
        [[ -n "$lbl" ]] && printf '%s\n' "$lbl" > "$d/temp${n}_label"
    done
}
# card <root> <name> <gtt_used> <gtt_total> <vram_used> <vram_total> [uW] [Hz]
card() {
    # Split: `local a=$1 b=$a` expands every word before assigning any of
    # them, so $root would still be unset. Same trap as in nordrassil's and
    # astromech's suites.
    local root="$1" c
    c="$root/class/drm/$2/device"
    mkdir -p "$c"
    printf '%s\n' "$3" > "$c/mem_info_gtt_used";  printf '%s\n' "$4" > "$c/mem_info_gtt_total"
    printf '%s\n' "$5" > "$c/mem_info_vram_used"; printf '%s\n' "$6" > "$c/mem_info_vram_total"
    if [[ -n "${7:-}" || -n "${8:-}" ]]; then
        mkdir -p "$c/hwmon/hwmon99"
        [[ -n "${7:-}" ]] && printf '%s\n' "$7" > "$c/hwmon/hwmon99/power1_average"
        [[ -n "${8:-}" ]] && printf '%s\n' "$8" > "$c/hwmon/hwmon99/freq1_input"
    fi
}
run() { ARAKYD_SYSFS="$1" bash "$ARA" "${@:2}"; }

# --- a Strix-Halo-shaped tree ------------------------------------------------
A="$T/a"
chip "$A" hwmon6 k10temp 1:46625:Tctl
chip "$A" hwmon5 amdgpu  1:45000:edge
chip "$A" hwmon2 nvme    1:37850:Composite 2:40850:"Sensor 1"
chip "$A" hwmon9 mt7925_phy0 1:42000:
card "$A" card1 47478419456 67147296768 512204800 536870912 15139000 907000000
out="$(run "$A" --print)"

echo "## units and labels"
has "CPU temperature, millidegrees to degrees" 'arakyd_temperature_celsius{role="cpu",chip="k10temp",device="",sensor="Tctl"} 46.625' "$out"
has "iGPU, by role not by chip path"           'arakyd_temperature_celsius{role="igpu",chip="amdgpu",device="",sensor="edge"} 45.000' "$out"
has "a label with a space survives"            'arakyd_temperature_celsius{role="nvme",chip="nvme",device="",sensor="Sensor 1"} 40.850' "$out"
has "no label falls back to tempN"             'arakyd_temperature_celsius{role="wifi",chip="mt7925_phy0",device="",sensor="temp1"} 42.000' "$out"
has "power, microwatts to watts"               'arakyd_gpu_power_watts{card="card1",device=""} 15.139000' "$out"
has "clock passes through in hertz"            'arakyd_gpu_clock_hertz{card="card1",device=""} 907000000' "$out"

echo "## unified memory — the reading node_exporter has no concept of"
has "GTT used"  'arakyd_gpu_memory_bytes{card="card1",device="",pool="gtt",state="used"} 47478419456' "$out"
has "GTT total" 'arakyd_gpu_memory_bytes{card="card1",device="",pool="gtt",state="total"} 67147296768' "$out"
# A 512 MiB carve-out exists and must not be rounded away: an earlier probe
# divided by 1 GiB in integer arithmetic and reported "no VRAM at all".
has "a small VRAM carve-out is reported exactly" 'arakyd_gpu_memory_bytes{card="card1",device="",pool="vram",state="total"} 536870912' "$out"

echo "## hwmon indices are not stable across boots"
B="$T/b"
chip "$B" hwmon3 k10temp 1:46625:Tctl      # was hwmon6
chip "$B" hwmon8 amdgpu  1:45000:edge      # was hwmon5
chip "$B" hwmon0 nvme    1:37850:Composite 2:40850:"Sensor 1"
chip "$B" hwmon1 mt7925_phy0 1:42000:
card "$B" card1 47478419456 67147296768 512204800 536870912 15139000 907000000
out_b="$(run "$B" --print)"
chk "the same hardware at different hwmonN gives identical output" \
    "$(grep -v '^arakyd_collector_last_run' <<<"$out"   | sort)" \
    "$(grep -v '^arakyd_collector_last_run' <<<"$out_b" | sort)"

echo "## a sensor that cannot be read is omitted, not reported as zero"
C="$T/c"
chip "$C" hwmon0 k10temp 1:46625:Tctl
printf 'N/A\n' > "$C/class/hwmon/hwmon0/temp2_input"
printf '%s\n' "Tccd1" > "$C/class/hwmon/hwmon0/temp2_label"
out_c="$(run "$C" --print)"
hasnt "a non-numeric reading emits nothing"  'sensor="Tccd1"' "$out_c"
hasnt "  and certainly not 0"                'Tccd1"} 0' "$out_c"
has   "the readable sensor is still there"   'arakyd_temperature_celsius{role="cpu",chip="k10temp",device="",sensor="Tctl"} 46.625' "$out_c"

echo "## an unknown chip is collected, not dropped"
D="$T/d"
chip "$D" hwmon0 some_future_sensor 1:33000:
out_d="$(run "$D" --print)"
has "role=other rather than silence" 'arakyd_temperature_celsius{role="other",chip="some_future_sensor",device="",sensor="temp1"} 33.000' "$out_d"

echo "## the meta metrics, which are the point of the dashboard working"
has "success is 1 when something was read"  'arakyd_collector_success 1' "$out"
has "the chip count is reported"            'arakyd_collector_hwmon_chips 4' "$out"
E="$T/empty"; mkdir -p "$E/class/hwmon" "$E/class/drm"
out_e="$(run "$E" --print)"
has "success is 0 when there was nothing"   'arakyd_collector_success 0' "$out_e"
has "  and the file is still valid"         'arakyd_collector_hwmon_chips 0' "$out_e"
if run "$E" --check >/dev/null 2>&1; then bad "--check should fail on an empty tree"
else ok "--check fails on an empty tree"; fi

echo "## exposition format"
run "$A" --print > "$T/fmt.prom"
fmt="$(python3 -c '
import re, pathlib
txt = pathlib.Path("'"$T"'/fmt.prom").read_text()
types, bad = {}, []
for i, line in enumerate(txt.splitlines(), 1):
    if line.startswith("# TYPE"):
        parts = line.split()
        types[parts[2]] = parts[3]; continue
    if not line or line.startswith("#"): continue
    m = re.match(r"^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{.*\})? (-?[0-9.]+|NaN|[-+]Inf)$", line)
    if not m: bad.append("line %d unparseable: %s" % (i, line))
    elif m.group(1) not in types: bad.append("line %d no TYPE for %s" % (i, m.group(1)))
print("VALID" if not bad else "; ".join(bad))
')"
chk "every sample parses and has a declared TYPE" VALID "$fmt"

echo "## --write is atomic and leaves nothing behind"
W="$T/textfile"; mkdir -p "$W"
run "$A" --write "$W"
if [[ -f "$W/arakyd.prom" ]]; then ok "arakyd.prom written"; else bad "arakyd.prom missing"; fi
# python, not `stat -c` (GNU only) or a bare `wc -l` (padded on macOS).
mode() { python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$1"; }
inode() { python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_ino)' "$1"; }
chk "mode 0644, so node_exporter can read it" 644 "$(mode "$W/arakyd.prom")"
chk "no temporary files left" 0 "$(( $(find "$W" -name 'arakyd.prom.*' | wc -l) ))"
# Atomic means replaced, not rewritten in place: a reader holding the old
# file keeps a whole one, and the new one appears whole.
before="$(inode "$W/arakyd.prom")"; run "$A" --write "$W"
if [[ "$(inode "$W/arakyd.prom")" != "$before" ]]; then ok "a rewrite replaces the file (rename), never edits it in place"
else bad "a rewrite edited arakyd.prom in place: a scrape could read half of it"; fi
# A run killed mid-write leaves its temp file; the next one clears it once it
# is a minute old, and leaves a fresh one alone (it may be another run's).
: > "$W/arakyd.prom.OLDTMP"; touch -t 202001010000 "$W/arakyd.prom.OLDTMP"; : > "$W/arakyd.prom.NEWTMP"
run "$A" --write "$W"
if [[ ! -e "$W/arakyd.prom.OLDTMP" ]]; then ok "an abandoned temp file is cleared"; else bad "an abandoned temp file was left"; fi
if [[ -e "$W/arakyd.prom.NEWTMP" ]]; then ok "  a fresh one is left alone"; else bad "a fresh temp file was removed"; fi
chk "content matches --print" \
    "$(grep -v last_run <<<"$(run "$A" --print)")" "$(grep -v last_run "$W/arakyd.prom")"
if run "$A" --write "$T/nope" >/dev/null 2>&1; then bad "--write should refuse a missing directory"
else ok "--write refuses a missing directory"; fi

echo "## a negative reading (Kamino item 132)"
N="$T/neg"
chip "$N" hwmon0 k10temp 1:-500:Tctl 2:-1500:Tccd1 3:46625:Tccd2
out_n="$(run "$N" --print)"
has "-500 m°C is -0.500, not 0.-500"   'arakyd_temperature_celsius{role="cpu",chip="k10temp",device="",sensor="Tctl"} -0.500' "$out_n"
has "-1500 m°C is -1.500"              'arakyd_temperature_celsius{role="cpu",chip="k10temp",device="",sensor="Tccd1"} -1.500' "$out_n"
run "$N" --print > "$T/fmt.prom"
fmt_n="$(python3 -c '
import re, pathlib
bad = [l for l in pathlib.Path("'"$T"'/fmt.prom").read_text().splitlines()
       if l and not l.startswith("#") and not re.match(r"^[a-zA-Z_:][a-zA-Z0-9_:]*(\{.*\})? -?[0-9]+(\.[0-9]+)?$", l)]
print("VALID" if not bad else "; ".join(bad))
')"
chk "  and the whole file still parses" VALID "$fmt_n"

echo "## two chips with one name (Kamino item 133)"
P="$T/pair"
chip "$P" hwmon0 nvme 1:37000:Composite
chip "$P" hwmon1 nvme 1:41000:Composite
mkdir -p "$P/devices/nvme0" "$P/devices/nvme1"
ln -s "$P/devices/nvme0" "$P/class/hwmon/hwmon0/device"; ln -s "$P/devices/nvme1" "$P/class/hwmon/hwmon1/device"
out_p="$(run "$P" --print)"
has "the first drive, by its device" 'arakyd_temperature_celsius{role="nvme",chip="nvme",device="nvme0",sensor="Composite"} 37.000' "$out_p"
has "the second, not a duplicate"     'arakyd_temperature_celsius{role="nvme",chip="nvme",device="nvme1",sensor="Composite"} 41.000' "$out_p"
chk "no two samples share a series" 0 "$(( $(grep -v '^#' <<<"$out_p" | sed 's/ [^ ]*$//' | sort | uniq -d | wc -l) ))"

echo "## a connector is not a card"
K="$T/conn"
chip "$K" hwmon0 k10temp 1:40000:Tctl
card "$K" card1 1 2 3 4
card "$K" card1-DP-1 9 9 9 9
out_k="$(run "$K" --print)"
hasnt "card1-DP-1 is not reported as a GPU" 'card="card1-DP-1"' "$out_k"

echo "## success needs every section that can be read (Kamino item 131)"
G="$T/gpu-gone"
chip "$G" hwmon0 k10temp 1:40000:Tctl
card "$G" card1 N/A N/A N/A N/A
out_g="$(run "$G" --print)"
has "a GPU whose readings are gone fails the run" 'arakyd_collector_success 0' "$out_g"
has "  and says which section came up empty"     'arakyd_collector_samples{section="gpu"} 0' "$out_g"
has "  while the temperatures were fine"         'arakyd_collector_samples{section="temperatures"} 1' "$out_g"
H="$T/no-gpu"
chip "$H" hwmon0 coretemp 1:40000:Package
out_h="$(run "$H" --print)"
has "a host with no such GPU still succeeds"     'arakyd_collector_success 1' "$out_h"

echo "## labels are escaped"
X="$T/esc"
chip "$X" hwmon0 k10temp 1:40000:'a"b\c'
out_x="$(run "$X" --print)"
has "a quote and a backslash in a label" 'arakyd_temperature_celsius{role="cpu",chip="k10temp",device="",sensor="a\"b\\c"} 40.000' "$out_x"

echo "## every role mapping"
R="$T/roles"
chip "$R" hwmon0 acpitz 1:30000:
chip "$R" hwmon1 cros_ec 1:31000:
chip "$R" hwmon2 r8169_0_bf00:00 1:32000:
out_r="$(run "$R" --print)"
has "acpitz is the board"        'arakyd_temperature_celsius{role="board",chip="acpitz",device="",sensor="temp1"} 30.000' "$out_r"
has "cros_ec is the board's EC"  'arakyd_temperature_celsius{role="board_ec",chip="cros_ec",device="",sensor="temp1"} 31.000' "$out_r"
has "r8169_* is the NIC"         'arakyd_temperature_celsius{role="nic",chip="r8169_0_bf00:00",device="",sensor="temp1"} 32.000' "$out_r"

echo "## --check says what it found"
chk_out="$(run "$A" --check 2>&1)"; chk_rc=$?
chk "it exits 0 when something was found" 0 "$chk_rc"
if grep -qE '^ +k10temp +role=cpu$' <<<"$chk_out"; then ok "  names each chip with its role"; else bad "--check did not list k10temp role=cpu"; fi
if grep -qE '^ +card1 +gtt_total=67147296768 bytes$' <<<"$chk_out"; then ok "  and the GPU's GTT size"; else bad "--check did not list card1's GTT"; fi

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
