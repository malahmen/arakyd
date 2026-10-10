#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# arakyd.sh — the readings node_exporter cannot take.
#
# node_exporter already covers CPU, memory, disk, network and raw hwmon, and
# this does not duplicate that work. It collects the things that need knowing
# which machine this is:
#
#   - Unified memory. On an AMD Strix Halo APU there is no dedicated VRAM: the
#     iGPU allocates out of system RAM through GTT. node_exporter reports 52 GiB
#     "used" while the GPU holds another 44, and no stock dashboard accounts for
#     it. This is the reading that decides whether a model will load.
#   - Temperatures ALREADY LABELLED BY ROLE. node_exporter emits
#     node_hwmon_temp_celsius keyed by a chip path like
#     pci0000:00_0000:00:18_3, which is correct and unreadable. Turning that
#     into "CPU" needs a two-hop PromQL join through node_hwmon_chip_names, and
#     the mapping from chip name to role is this machine's knowledge, not
#     node_exporter's. So it is applied here, once.
#   - amdgpu package power and core clock, which hwmon exposes and
#     node_exporter does not surface in a usable form.
#
# Output is the Prometheus text format, for node_exporter's textfile collector.
# Nothing is served; nothing listens. A timer writes the file, node_exporter
# reads it on scrape.
#
# hwmon indices are NOT stable across boots — they follow device probe order —
# so every chip here is discovered by its `name`, never by hwmonN.
#
# Needs no root: everything read is world-readable sysfs.
# -----------------------------------------------------------------------------
set -euo pipefail

VERSION="1.0.0"
SELF="${0##*/}"

# Test seam: the suite points these at a fabricated tree, because a runner has
# no Strix Halo and this host cannot be made to have different hardware.
SYSFS="${ARAKYD_SYSFS:-/sys}"

# chip `name` -> role. The one genuinely machine-specific thing here, and the
# reason this project is not generic. A name not listed is still collected, with
# role="other", so a new sensor appears rather than vanishing.
_role_for() {
    case "$1" in
        k10temp)       printf 'cpu' ;;
        amdgpu)        printf 'igpu' ;;
        nvme)          printf 'nvme' ;;
        acpitz)        printf 'board' ;;
        cros_ec)       printf 'board_ec' ;;
        r8169_*)       printf 'nic' ;;
        mt7925_*|iwlwifi_*) printf 'wifi' ;;
        *)             printf 'other' ;;
    esac
}

# A label value must not contain a bare backslash, quote or newline.
_esc() { printf '%s' "${1//\\/\\\\}" | sed 's/"/\\"/g' | tr -d '\n'; }

# _num FILE — the file's first line if it is an integer, else nothing. Guards
# against a sensor that reads "N/A" or goes absent between glob and read.
_num() {
    local v
    v="$(head -1 "$1" 2>/dev/null || true)"
    [[ "$v" =~ ^-?[0-9]+$ ]] && printf '%s' "$v"
}

emit_temperatures() {
    local d name role f idx lbl milli
    printf '# HELP arakyd_temperature_celsius Sensor temperature, labelled by the role it reports on.\n'
    printf '# TYPE arakyd_temperature_celsius gauge\n'
    for d in "$SYSFS"/class/hwmon/hwmon*; do
        [[ -r "$d/name" ]] || continue
        name="$(cat "$d/name" 2>/dev/null || true)"
        [[ -n "$name" ]] || continue
        role="$(_role_for "$name")"
        for f in "$d"/temp*_input; do
            [[ -r "$f" ]] || continue
            milli="$(_num "$f")"; [[ -n "$milli" ]] || continue
            idx="$(basename "$f")"; idx="${idx#temp}"; idx="${idx%_input}"
            lbl="$(cat "${d}/temp${idx}_label" 2>/dev/null || true)"
            [[ -n "$lbl" ]] || lbl="temp${idx}"
            # Integer millidegrees to degrees, without bc: awk is already a
            # dependency of nothing here, so do it in the shell.
            printf 'arakyd_temperature_celsius{role="%s",chip="%s",sensor="%s"} %s.%03d\n' \
                "$(_esc "$role")" "$(_esc "$name")" "$(_esc "$lbl")" \
                "$(( milli / 1000 ))" "$(( milli % 1000 ))"
        done
    done
}

emit_gpu() {
    local c card uw hz used total
    printf '# HELP arakyd_gpu_memory_bytes iGPU memory by pool. On a unified-memory APU this is system RAM the GPU holds, not separate VRAM.\n'
    printf '# TYPE arakyd_gpu_memory_bytes gauge\n'
    printf '# HELP arakyd_gpu_power_watts Average package power reported by amdgpu.\n'
    printf '# TYPE arakyd_gpu_power_watts gauge\n'
    printf '# HELP arakyd_gpu_clock_hertz iGPU shader clock.\n'
    printf '# TYPE arakyd_gpu_clock_hertz gauge\n'
    for c in "$SYSFS"/class/drm/card*/device; do
        [[ -d "$c" ]] || continue
        card="${c%/device}"; card="${card##*/}"
        local pool
        for pool in gtt vram; do
            used="$(_num "${c}/mem_info_${pool}_used")"
            total="$(_num "${c}/mem_info_${pool}_total")"
            # vram_total is legitimately 0 on this APU — emitted, because "there
            # is no dedicated VRAM" is a fact worth being able to see.
            [[ -n "$used" ]] && printf 'arakyd_gpu_memory_bytes{card="%s",pool="%s",state="used"} %s\n' "$(_esc "$card")" "$pool" "$used"
            [[ -n "$total" ]] && printf 'arakyd_gpu_memory_bytes{card="%s",pool="%s",state="total"} %s\n' "$(_esc "$card")" "$pool" "$total"
        done
        # power and clock live on the card's hwmon child, whose index is as
        # unstable as any other.
        local h
        for h in "$c"/hwmon/hwmon*; do
            [[ -d "$h" ]] || continue
            uw="$(_num "${h}/power1_average")"
            [[ -n "$uw" ]] && printf 'arakyd_gpu_power_watts{card="%s"} %s.%06d\n' "$(_esc "$card")" "$(( uw / 1000000 ))" "$(( uw % 1000000 ))"
            hz="$(_num "${h}/freq1_input")"
            [[ -n "$hz" ]] && printf 'arakyd_gpu_clock_hertz{card="%s"} %s\n' "$(_esc "$card")" "$hz"
        done
    done
}

# Meta, and the reason it exists: node_exporter being up tells you the host is
# reachable. It does not tell you this collector ran. Without these, "exporter
# up but collector silently failing" is indistinguishable from "nothing to
# report" — and a dashboard that cannot tell them apart is the thing this whole
# project is supposed to avoid.
emit_meta() {
    local ok="$1" started="$2" chips=0 d
    # Counted by iterating, not by `find -name 'hwmon*'`: that pattern also
    # matches the PARENT directory class/hwmon, which made every count one too
    # high. And counting only chips with a readable `name` means this number is
    # what was actually collectable, not what happened to exist.
    for d in "$SYSFS"/class/hwmon/hwmon*; do
        [[ -r "$d/name" ]] && chips=$((chips + 1))
    done
    printf '# HELP arakyd_collector_success Whether the last collection completed.\n'
    printf '# TYPE arakyd_collector_success gauge\n'
    printf 'arakyd_collector_success %s\n' "$ok"
    printf '# HELP arakyd_collector_last_run_seconds Unix time of the last collection.\n'
    printf '# TYPE arakyd_collector_last_run_seconds gauge\n'
    printf 'arakyd_collector_last_run_seconds %s\n' "$started"
    printf '# HELP arakyd_collector_hwmon_chips Number of hwmon chips found.\n'
    printf '# TYPE arakyd_collector_hwmon_chips gauge\n'
    printf 'arakyd_collector_hwmon_chips %s\n' "$chips"
    printf '# HELP arakyd_build_info Collector version.\n'
    printf '# TYPE arakyd_build_info gauge\n'
    printf 'arakyd_build_info{version="%s"} 1\n' "$(_esc "$VERSION")"
}

collect() {
    local started ok=0 body samples
    started="$(date +%s)"
    body="$( { emit_temperatures; emit_gpu; } 2>/dev/null || true )"
    # Counted in SAMPLES, not bytes. emit_* always print their # HELP and
    # # TYPE headers, so "is the output non-empty" was true even when nothing
    # at all had been read — success could never be 0, which made the metric
    # that exists to detect a broken collector unable to detect one.
    samples="$(grep -cvE '^(#|[[:space:]]*$)' <<<"$body" || true)"
    [[ "${samples:-0}" -gt 0 ]] && ok=1
    [[ -n "$body" ]] && printf '%s\n' "$body"
    emit_meta "$ok" "$started"
}

usage() {
    cat >&2 <<HELPDOC
${SELF} ${VERSION} — readings node_exporter cannot take (Strix Halo / amdgpu)

USAGE
  ${SELF} --print              write the metrics to stdout
  ${SELF} --write DIR          write DIR/arakyd.prom atomically (node_exporter
                               textfile collector directory)
  ${SELF} --check              list what was discovered, and exit non-zero if
                               nothing was
  ${SELF} --version | --help

ENVIRONMENT
  ARAKYD_SYSFS                 sysfs root (default /sys); the test suite points
                               this at a fabricated tree
HELPDOC
}

main() {
    case "${1:---print}" in
        --print) collect ;;
        --write)
            local dir="${2:-}" out tmp
            [[ -n "$dir" ]] || { echo "[error] --write needs a directory" >&2; exit 1; }
            [[ -d "$dir" ]] || { echo "[error] not a directory: ${dir}" >&2; exit 1; }
            out="${dir%/}/arakyd.prom"
            # Atomic: node_exporter reads the whole file on scrape and a partial
            # read is a parse error, so it must never see one being written.
            tmp="$(mktemp "${out}.XXXXXX")"
            trap 'rm -f "$tmp"' EXIT
            collect > "$tmp"
            chmod 0644 "$tmp"
            mv -f "$tmp" "$out"
            trap - EXIT
            ;;
        --check)
            local n=0 d name
            for d in "$SYSFS"/class/hwmon/hwmon*; do
                [[ -r "$d/name" ]] || continue
                name="$(cat "$d/name" 2>/dev/null || true)"; [[ -n "$name" ]] || continue
                printf '  %-28s role=%s\n' "$name" "$(_role_for "$name")"
                n=$((n + 1))
            done
            for d in "$SYSFS"/class/drm/card*/device; do
                [[ -f "${d}/mem_info_gtt_total" ]] || continue
                printf '  %-28s gtt_total=%s bytes\n' "$(basename "$(dirname "$d")")" "$(_num "${d}/mem_info_gtt_total")"
                n=$((n + 1))
            done
            (( n )) || { echo "[error] nothing found under ${SYSFS} — wrong ARAKYD_SYSFS, or unsupported hardware" >&2; exit 1; }
            ;;
        --version) printf '%s %s\n' "$SELF" "$VERSION" ;;
        -h|--help) usage ;;
        *) usage; exit 1 ;;
    esac
}

main "$@"
