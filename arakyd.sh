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
#   - amdgpu's package power (PPT - on an APU the whole package, CPU and GPU
#     together, not the iGPU alone) and core clock, which hwmon exposes and
#     node_exporter does not surface in a usable form; and how busy the iGPU
#     is (amdgpu's gpu_busy_percent), which node_exporter has no collector for.
#   - Disk size and free space of the filesystems that hold the data. On an
#     image-based host (Bazzite) the root is a read-only composefs and the data
#     is on /var; node_exporter runs here without its filesystem collector
#     (the host root is not mounted into its container), so these are read
#     with df, on the host, for the paths in ARAKYD_FILESYSTEMS.
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

VERSION="1.2.0"
SELF="${0##*/}"

# Test seam: the suite points these at a fabricated tree, because a runner has
# no Strix Halo and this host cannot be made to have different hardware.
SYSFS="${ARAKYD_SYSFS:-/sys}"
# The filesystems whose size and free space are reported, by a path on each
# (space-separated). /var: where an image-based host keeps its data.
FILESYSTEMS="${ARAKYD_FILESYSTEMS:-/var}"

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

# _fixed INT DIGITS — INT / 10^DIGITS as a decimal, sign kept whole.
#
# printf '%s.%03d' of $((m/1000)) and $((m%1000)) rendered -500 as "0.-500",
# which node_exporter cannot parse - and one unparseable line drops the WHOLE
# textfile, collector_success with it, so a single odd sensor blanked every
# arakyd_* series (Kamino item 132).
_fixed() {
    local v="$1" n="$2" sign="" scale=1 i
    if (( v < 0 )); then sign="-"; v=$(( -v )); fi
    for (( i = 0; i < n; i++ )); do scale=$(( scale * 10 )); done
    printf '%s%d.%0*d' "$sign" "$(( v / scale ))" "$n" "$(( v % scale ))"
}

# _device DIR — what the chip or card is attached to (a PCI address such as
# 0000:c2:00.0, or a device name such as nvme0). Two chips can share a `name`
# - two NVMe drives, two amdgpus - and without this their series were
# identical and node_exporter dropped one (Kamino item 133).
_device() {
    local t
    # A link, or nothing: `readlink -f` of a missing last component prints
    # the path anyway, which would label a chip with no device link "device".
    [[ -L "$1/device" ]] || return 0
    t="$(readlink -f "$1/device" 2>/dev/null || true)"
    printf '%s' "${t##*/}"
}

# _num FILE — the file's first line if it is an integer, else nothing. Guards
# against a sensor that reads "N/A" or goes absent between glob and read.
_num() {
    local v
    v="$(head -1 "$1" 2>/dev/null || true)"
    [[ "$v" =~ ^-?[0-9]+$ ]] && printf '%s' "$v"
}

emit_temperatures() {
    local d name role dev f idx lbl milli
    printf '# HELP arakyd_temperature_celsius Sensor temperature, labelled by the role it reports on.\n'
    printf '# TYPE arakyd_temperature_celsius gauge\n'
    for d in "$SYSFS"/class/hwmon/hwmon*; do
        [[ -r "$d/name" ]] || continue
        name="$(cat "$d/name" 2>/dev/null || true)"
        [[ -n "$name" ]] || continue
        role="$(_role_for "$name")"
        dev="$(_device "$d")"
        for f in "$d"/temp*_input; do
            [[ -r "$f" ]] || continue
            milli="$(_num "$f")"; [[ -n "$milli" ]] || continue
            idx="$(basename "$f")"; idx="${idx#temp}"; idx="${idx%_input}"
            lbl="$(cat "${d}/temp${idx}_label" 2>/dev/null || true)"
            [[ -n "$lbl" ]] || lbl="temp${idx}"
            # Integer millidegrees to degrees, without bc: awk is already a
            # dependency of nothing here, so do it in the shell.
            printf 'arakyd_temperature_celsius{role="%s",chip="%s",device="%s",sensor="%s"} %s\n' \
                "$(_esc "$role")" "$(_esc "$name")" "$(_esc "$dev")" "$(_esc "$lbl")" \
                "$(_fixed "$milli" 3)"
        done
    done
}

emit_gpu() {
    local c card dev uw hz used total busy
    printf '# HELP arakyd_gpu_memory_bytes iGPU memory by pool. On a unified-memory APU this is system RAM the GPU holds, not separate VRAM.\n'
    printf '# TYPE arakyd_gpu_memory_bytes gauge\n'
    printf '# HELP arakyd_gpu_power_watts Average package power (PPT) reported by amdgpu: on an APU, CPU and GPU together.\n'
    printf '# TYPE arakyd_gpu_power_watts gauge\n'
    printf '# HELP arakyd_gpu_clock_hertz iGPU shader clock.\n'
    printf '# TYPE arakyd_gpu_clock_hertz gauge\n'
    printf '# HELP arakyd_gpu_busy_ratio How busy the iGPU is, 0 to 1 (amdgpu gpu_busy_percent: a sample, not an average).\n'
    printf '# TYPE arakyd_gpu_busy_ratio gauge\n'
    # card[0-9]*: card1-DP-1 and the other connectors also have a device link.
    for c in "$SYSFS"/class/drm/card[0-9]*/device; do
        [[ -d "$c" ]] || continue
        card="${c%/device}"; card="${card##*/}"
        [[ "$card" =~ ^card[0-9]+$ ]] || continue
        # `card` is the DRM minor, as unstable as hwmonN; `device` is not.
        dev="$(_device "${c%/device}")"
        local pool
        for pool in gtt vram; do
            used="$(_num "${c}/mem_info_${pool}_used")"
            total="$(_num "${c}/mem_info_${pool}_total")"
            # vram_total is legitimately 0 on this APU — emitted, because "there
            # is no dedicated VRAM" is a fact worth being able to see.
            [[ -n "$used" ]] && printf 'arakyd_gpu_memory_bytes{card="%s",device="%s",pool="%s",state="used"} %s\n' "$(_esc "$card")" "$(_esc "$dev")" "$pool" "$used"
            [[ -n "$total" ]] && printf 'arakyd_gpu_memory_bytes{card="%s",device="%s",pool="%s",state="total"} %s\n' "$(_esc "$card")" "$(_esc "$dev")" "$pool" "$total"
        done
        busy="$(_num "${c}/gpu_busy_percent")"
        [[ -n "$busy" ]] && printf 'arakyd_gpu_busy_ratio{card="%s",device="%s"} %s\n' "$(_esc "$card")" "$(_esc "$dev")" "$(_fixed "$busy" 2)"
        # power and clock live on the card's hwmon child, whose index is as
        # unstable as any other.
        local h
        for h in "$c"/hwmon/hwmon*; do
            [[ -d "$h" ]] || continue
            uw="$(_num "${h}/power1_average")"
            [[ -n "$uw" ]] && printf 'arakyd_gpu_power_watts{card="%s",device="%s"} %s\n' "$(_esc "$card")" "$(_esc "$dev")" "$(_fixed "$uw" 6)"
            hz="$(_num "${h}/freq1_input")"
            [[ -n "$hz" ]] && printf 'arakyd_gpu_clock_hertz{card="%s",device="%s"} %s\n' "$(_esc "$card")" "$(_esc "$dev")" "$hz"
        done
    done
}

# emit_filesystems — size and free bytes of the filesystem holding each path
# in FILESYSTEMS, labelled by its mount point. Free is what an ordinary user
# can still write (df's "avail"), not counting the root-reserved blocks.
emit_filesystems() {
    local p line size avail mnt
    printf '# HELP arakyd_filesystem_size_bytes Size of the filesystem holding a configured path.\n'
    printf '# TYPE arakyd_filesystem_size_bytes gauge\n'
    printf '# HELP arakyd_filesystem_avail_bytes Free space on it an ordinary user can write.\n'
    printf '# TYPE arakyd_filesystem_avail_bytes gauge\n'
    for p in $FILESYSTEMS; do
        [[ -e "$p" ]] || continue
        line="$(df -P -B1 -- "$p" 2>/dev/null | awk 'NR == 2 { print $2, $4, $6 }')" || continue
        read -r size avail mnt <<<"$line"
        [[ "$size" =~ ^[0-9]+$ && "$avail" =~ ^[0-9]+$ && -n "$mnt" ]] || continue
        printf 'arakyd_filesystem_size_bytes{mountpoint="%s"} %s\n' "$(_esc "$mnt")" "$size"
        printf 'arakyd_filesystem_avail_bytes{mountpoint="%s"} %s\n' "$(_esc "$mnt")" "$avail"
    done
}

# Meta, and the reason it exists: node_exporter being up tells you the host is
# reachable. It does not tell you this collector ran. Without these, "exporter
# up but collector silently failing" is indistinguishable from "nothing to
# report" — and a dashboard that cannot tell them apart is the thing this whole
# project is supposed to avoid.
emit_meta() {
    local ok="$1" started="$2" n_temp="$3" n_gpu="$4" n_fs="${5:-0}" chips=0 d
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
    printf '# HELP arakyd_collector_samples Samples the last collection produced, per section: 0 where a section had nothing to read.\n'
    printf '# TYPE arakyd_collector_samples gauge\n'
    printf 'arakyd_collector_samples{section="temperatures"} %s\n' "$n_temp"
    printf 'arakyd_collector_samples{section="gpu"} %s\n' "$n_gpu"
    printf 'arakyd_collector_samples{section="filesystems"} %s\n' "$n_fs"
    printf '# HELP arakyd_collector_last_run_seconds Unix time of the last collection. A file that stopped being rewritten keeps being served with this value: compare it with time().\n'
    printf '# TYPE arakyd_collector_last_run_seconds gauge\n'
    printf 'arakyd_collector_last_run_seconds %s\n' "$started"
    printf '# HELP arakyd_collector_hwmon_chips Number of hwmon chips found.\n'
    printf '# TYPE arakyd_collector_hwmon_chips gauge\n'
    printf 'arakyd_collector_hwmon_chips %s\n' "$chips"
    printf '# HELP arakyd_build_info Collector version.\n'
    printf '# TYPE arakyd_build_info gauge\n'
    printf 'arakyd_build_info{version="%s"} 1\n' "$(_esc "$VERSION")"
}

# _samples TEXT — its sample lines, not counting # HELP / # TYPE.
_samples() { grep -cvE '^(#|[[:space:]]*$)' <<<"$1" || true; }

# _gpu_expected — a card with amdgpu's memory files: its readings should be
# there, and none is a failure rather than a host with no such GPU.
_gpu_expected() {
    local c
    for c in "$SYSFS"/class/drm/card[0-9]*/device; do
        [[ -e "${c}/mem_info_gtt_total" ]] && return 0
    done
    return 1
}

collect() {
    local started ok=0 temps gpu fs n_temp n_gpu n_fs
    started="$(date +%s)"
    temps="$( { emit_temperatures; } 2>/dev/null || true )"
    gpu="$( { emit_gpu; } 2>/dev/null || true )"
    fs="$( { emit_filesystems; } 2>/dev/null || true )"
    # Counted in SAMPLES, not bytes. emit_* always print their # HELP and
    # # TYPE headers, so "is the output non-empty" was true even when nothing
    # at all had been read — success could never be 0, which made the metric
    # that exists to detect a broken collector unable to detect one.
    #
    # And per section: one temperature used to make the whole run a success
    # with every GPU reading gone (Kamino item 131). Success now needs a
    # temperature, and a GPU reading wherever a GPU's files are there to read.
    # Filesystems do not decide success: they are counted, and a missing
    # section shows as 0 here.
    n_temp="$(_samples "$temps")"; n_gpu="$(_samples "$gpu")"; n_fs="$(_samples "$fs")"
    if (( ${n_temp:-0} > 0 )) && { (( ${n_gpu:-0} > 0 )) || ! _gpu_expected; }; then ok=1; fi
    [[ -n "$temps" ]] && printf '%s\n' "$temps"
    [[ -n "$gpu" ]] && printf '%s\n' "$gpu"
    [[ -n "$fs" ]] && printf '%s\n' "$fs"
    emit_meta "$ok" "$started" "${n_temp:-0}" "${n_gpu:-0}" "${n_fs:-0}"
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
  ARAKYD_FILESYSTEMS           paths whose filesystems' size and free space are
                               reported, space-separated (default /var)
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
            # A run killed mid-write (TimeoutStartSec, a reboot) leaves its
            # temp file behind, since no trap runs on SIGKILL. node_exporter
            # reads only *.prom, so they are clutter, not errors - cleared
            # here once they are a minute old.
            find "$dir" -maxdepth 1 -name 'arakyd.prom.??????' -mmin +1 -delete 2>/dev/null || true
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
            for d in "$SYSFS"/class/drm/card[0-9]*/device; do
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
