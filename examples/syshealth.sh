#!/usr/bin/env bash
# syshealth.sh — system health snapshot for worlock
# Checks: SMART on all physical drives, md RAID status, GPU VRAM,
#         Ollama loaded models, top 5 disk consumers under /mnt/raid0
#
# Usage: ./syshealth.sh [--no-smart]   (--no-smart skips slow SMART polls)

set -euo pipefail

NO_SMART=0
[[ "${1:-}" == "--no-smart" ]] && NO_SMART=1

OLLAMA_API="${OLLAMA_HOST:-http://localhost:11434}"

# ── colour helpers ────────────────────────────────────────────────────────────
R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'
C=$'\033[36m'; B=$'\033[1m';  N=$'\033[0m'

hr()  { printf "${C}%-72s${N}\n" "$(printf '%.0s─' {1..72})"; }
hdr() { hr; echo "${B}${C}  $*${N}"; hr; }

ok()   { echo "  ${G}✓${N}  $*"; }
warn() { echo "  ${Y}!${N}  $*"; }
err()  { echo "  ${R}✗${N}  $*"; }

# ── 1. SMART health ───────────────────────────────────────────────────────────
hdr "SMART — Physical Drive Health"

if [[ "$NO_SMART" -eq 1 ]]; then
    echo "  (skipped — pass no args to enable)"
elif ! command -v smartctl &>/dev/null; then
    warn "smartctl not found (apt install smartmontools)"
else
    # Enumerate physical block devices (exclude loop, ram, md, partitions)
    while read -r dev; do
        devpath="/dev/$dev"
        result=$(sudo smartctl -H "$devpath" 2>/dev/null | grep -E 'overall|result|status' || true)
        if echo "$result" | grep -qi 'PASSED\|OK'; then
            ok "$devpath  — PASSED"
        elif echo "$result" | grep -qi 'FAILED'; then
            err "$devpath  — FAILED  ← ATTENTION"
        else
            warn "$devpath  — no SMART data (USB/virtual/unsupported)"
        fi
    done < <(lsblk -d -o NAME,TYPE | awk '$2=="disk"{print $1}')
fi

# ── 2. MD RAID status ─────────────────────────────────────────────────────────
hdr "RAID — md Array Status"

if [[ ! -f /proc/mdstat ]]; then
    warn "/proc/mdstat not found"
else
    # Summary line per array — RAID-0 has no [UU] indicator, use mdadm State
    grep -E '^md[0-9]' /proc/mdstat | while read -r line; do
        arrname=$(echo "$line" | awk '{print $1}')
        level=$(echo "$line"   | awk '{print $4}')   # e.g. raid0, raid1
        devs=$(echo "$line"    | awk '{$1=$2=$3=$4=""; print $0}' | xargs)

        # For RAID-1/5/6 look for sync state; RAID-0 has none
        sync_state=$(echo "$line" | grep -oE '\[[_U]+\]' || true)

        if [[ -n "$sync_state" ]]; then
            if echo "$sync_state" | grep -q '_'; then
                err "$arrname  $level  $sync_state  ← degraded  ($devs)"
            else
                ok  "$arrname  $level  $sync_state  ($devs)"
            fi
        else
            # RAID-0: check via mdadm State field
            state=$(sudo mdadm --detail "/dev/$arrname" 2>/dev/null \
                | awk '/^\s+State :/{print $3}' || echo "unknown")
            if [[ "$state" == "clean" || "$state" == "active" ]]; then
                ok  "$arrname  $level  [clean]  ($devs)"
            else
                warn "$arrname  $level  state=$state  ($devs)"
            fi
        fi
    done

    # mdadm detail for md0 if available
    if [[ -b /dev/md0 ]] && command -v mdadm &>/dev/null; then
        echo ""
        sudo mdadm --detail /dev/md0 2>/dev/null \
            | grep -E 'State|Raid Level|Array Size|Active Devices|Failed|Rebuild' \
            | sed 's/^/    /'
    fi
fi

# ── 3. GPU VRAM ───────────────────────────────────────────────────────────────
hdr "GPU — VRAM & Utilization"

if command -v nvidia-smi &>/dev/null; then
    nvidia-smi \
        --query-gpu=index,name,utilization.gpu,utilization.memory,memory.used,memory.total,temperature.gpu \
        --format=csv,noheader \
    | while IFS=',' read -r idx gname gpu_pct mem_pct mem_used mem_total temp; do
        used_n=$(echo "$mem_used" | tr -d ' MiB')
        total_n=$(echo "$mem_total" | tr -d ' MiB')
        pct=$(( used_n * 100 / total_n ))
        bar=$(printf '%-20s' "$(printf '%.0s█' $(seq 1 $((pct/5))))")
        printf "  GPU%-2s %-26s  %3d%% VRAM [%s] %s/%s  %s°C\n" \
            "$idx" "$gname" "$pct" "$bar" \
            "${mem_used// /}" "${mem_total// /}" "${temp// /}"
    done
else
    warn "nvidia-smi not found"
fi

# ── 4. Ollama loaded models ───────────────────────────────────────────────────
hdr "Ollama — Loaded Models  (${OLLAMA_API}/api/ps)"

if curl -sf --max-time 3 "$OLLAMA_API/api/tags" &>/dev/null; then
    ps_json=$(curl -sf --max-time 3 "$OLLAMA_API/api/ps" 2>/dev/null || echo '{"models":[]}')
    count=$(echo "$ps_json" | jq -r '.models | length')

    if [[ "$count" -eq 0 ]]; then
        echo "  (no models currently loaded)"
    else
        echo "$ps_json" | jq -r '.models[] |
            "  \(.name)  \(.details.quantization_level)  \(.context_length) ctx  " +
            ((.size_vram / 1073741824) | tostring | .[0:5]) + " GB vram  " +
            "expires: \(.expires_at)"'
    fi
else
    warn "Ollama not reachable at $OLLAMA_API"
fi

# ── 5. Disk usage summary ─────────────────────────────────────────────────────
hdr "Disk — Mount Usage"

df -h /mnt/raid0 /mnt/wd_storage /mnt/sdf1 / 2>/dev/null \
    | awk 'NR==1{print "  "$0} NR>1{
        pct=$5+0
        if(pct>=90) color="\033[31m"
        else if(pct>=75) color="\033[33m"
        else color="\033[32m"
        print "  "color $0"\033[0m"
    }'

# ── 6. Top-level directory sizes under /mnt/raid0 ────────────────────────────
hdr "Disk — Top-level sizes under /mnt/raid0  (depth=1, 10s timeout)"

if mountpoint -q /mnt/raid0 2>/dev/null; then
    # depth=1 only — depth=2 on multi-million-file arrays takes hours
    timeout 10s sudo du -h --max-depth=1 /mnt/raid0 2>/dev/null \
        | sort -rh \
        | tail -n +2 \
        | head -10 \
        | sed 's/^/  /' \
    ; [[ $? -eq 124 ]] && warn "du hit 10s timeout — partial results above (array too large for full scan)"  || true
else
    warn "/mnt/raid0 is not mounted"
fi

# ── footer ────────────────────────────────────────────────────────────────────
hr
printf "  Generated: %s\n\n" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
