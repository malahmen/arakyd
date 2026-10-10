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
has "CPU temperature, millidegrees to degrees" 'arakyd_temperature_celsius{role="cpu",chip="k10temp",sensor="Tctl"} 46.625' "$out"
has "iGPU, by role not by chip path"           'arakyd_temperature_celsius{role="igpu",chip="amdgpu",sensor="edge"} 45.000' "$out"
has "a label with a space survives"            'arakyd_temperature_celsius{role="nvme",chip="nvme",sensor="Sensor 1"} 40.850' "$out"
has "no label falls back to tempN"             'arakyd_temperature_celsius{role="wifi",chip="mt7925_phy0",sensor="temp1"} 42.000' "$out"
has "power, microwatts to watts"               'arakyd_gpu_power_watts{card="card1"} 15.139000' "$out"
has "clock passes through in hertz"            'arakyd_gpu_clock_hertz{card="card1"} 907000000' "$out"

echo "## unified memory — the reading node_exporter has no concept of"
has "GTT used"  'arakyd_gpu_memory_bytes{card="card1",pool="gtt",state="used"} 47478419456' "$out"
has "GTT total" 'arakyd_gpu_memory_bytes{card="card1",pool="gtt",state="total"} 67147296768' "$out"
# A 512 MiB carve-out exists and must not be rounded away: an earlier probe
# divided by 1 GiB in integer arithmetic and reported "no VRAM at all".
has "a small VRAM carve-out is reported exactly" 'arakyd_gpu_memory_bytes{card="card1",pool="vram",state="total"} 536870912' "$out"

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
has   "the readable sensor is still there"   'arakyd_temperature_celsius{role="cpu",chip="k10temp",sensor="Tctl"} 46.625' "$out_c"

echo "## an unknown chip is collected, not dropped"
D="$T/d"
chip "$D" hwmon0 some_future_sensor 1:33000:
out_d="$(run "$D" --print)"
has "role=other rather than silence" 'arakyd_temperature_celsius{role="other",chip="some_future_sensor",sensor="temp1"} 33.000' "$out_d"

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
chk "mode 0644, so node_exporter can read it" 644 "$(stat -c %a "$W/arakyd.prom")"
chk "no temporary files left" 0 "$(find "$W" -name 'arakyd.prom.*' | wc -l)"
chk "content matches --print" \
    "$(grep -v last_run <<<"$(run "$A" --print)")" "$(grep -v last_run "$W/arakyd.prom")"
if run "$A" --write "$T/nope" >/dev/null 2>&1; then bad "--write should refuse a missing directory"
else ok "--write refuses a missing directory"; fi

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
