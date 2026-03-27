#!/usr/bin/env bash
# peek.sh — inspect Ollama's current state at a glance
#
# Shows: loaded model, GPU utilization, runner CPU, pending requests,
# elapsed time, and a stuck heuristic.
#
# Usage:
#   ./peek.sh              # single snapshot
#   ./peek.sh --watch      # refresh every 3s (ctrl-c to exit)
#   ./peek.sh --watch 5    # custom interval in seconds

set -euo pipefail

OLLAMA_API="${OLLAMA_HOST:-http://localhost:11434}"

# GPU util threshold below which we consider a model potentially stuck (%)
STUCK_GPU_THRESHOLD=2
# Minimum seconds a generation must be running before we flag it as possibly stuck
STUCK_MIN_ELAPSED=60

WATCH=0
INTERVAL=3

while [[ $# -gt 0 ]]; do
    case "$1" in
        --watch) WATCH=1; shift
                 [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]] && { INTERVAL="$1"; shift; } ;;
        *) echo "Usage: peek.sh [--watch [interval_seconds]]" >&2; exit 1 ;;
    esac
done

snapshot() {
    local now_epoch
    now_epoch=$(date +%s)
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')

    echo "━━━ Ollama peek — $ts ━━━"

    # --- /api/ps: loaded model ---
    local ps_json count
    ps_json=$(curl -sf --max-time 3 "$OLLAMA_API/api/ps" 2>/dev/null || echo '{"models":[]}')
    count=$(echo "$ps_json" | jq -r '.models | length')

    if [[ "$count" -eq 0 ]]; then
        echo "  MODEL     : (none loaded)"
    else
        local name family quant ctx vram expires
        name=$(echo    "$ps_json" | jq -r '.models[0].name')
        family=$(echo  "$ps_json" | jq -r '.models[0].details.family // "?"')
        quant=$(echo   "$ps_json" | jq -r '.models[0].details.quantization_level // "?"')
        ctx=$(echo     "$ps_json" | jq -r '.models[0].context_length // "?"')
        vram=$(echo    "$ps_json" | jq -r '.models[0].size_vram')
        expires=$(echo "$ps_json" | jq -r '.models[0].expires_at')

        local vram_gb
        vram_gb=$(awk "BEGIN {printf \"%.1f\", $vram/1073741824}")

        # Seconds until keep-alive expiry
        local exp_epoch secs_left
        local exp_trimmed
        exp_trimmed=$(echo "$expires" | sed 's/\(\.[0-9]*\)\([-+]\)/\2/')
        exp_epoch=$(date -d "$exp_trimmed" +%s 2>/dev/null || echo "$now_epoch")
        secs_left=$(( exp_epoch - now_epoch ))

        echo "  MODEL     : $name  ($family, $quant)"
        echo "  CTX       : $ctx tokens"
        echo "  VRAM      : ${vram_gb} GB"
        if [[ $secs_left -lt 0 ]]; then
            echo "  EXPIRES   : OVERDUE by $(( -secs_left ))s  (keep-alive lapsed — model held by active request(s))"
        else
            echo "  EXPIRES   : ${secs_left}s  (keep-alive countdown)"
        fi
    fi

    echo ""

    # --- GPU utilization ---
    if command -v nvidia-smi &>/dev/null; then
        echo "  GPU UTIL  :"
        nvidia-smi \
            --query-gpu=index,name,utilization.gpu,utilization.memory,memory.used,memory.total \
            --format=csv,noheader \
        | while IFS=',' read -r idx gname gpu_pct mem_pct mem_used mem_total; do
            printf "    GPU%s %-22s  compute: %s   mem: %s / %s\n" \
                "$idx" "$gname" "${gpu_pct// /}" "${mem_used// /}" "${mem_total// /}"
        done

        # Grab total GPU util for stuck heuristic
        local total_gpu_util
        total_gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader \
            | awk '{sum += int($1)} END {print sum}')
    else
        echo "  GPU UTIL  : nvidia-smi not available"
        local total_gpu_util=100  # assume OK if we can't check
    fi

    echo ""

    # --- ollama processes ---
    echo "  PROCESSES :"
    local runner_pids runner_cpu
    runner_pids=$(pgrep -f 'ollama runner' 2>/dev/null || true)

    if [[ -z "$runner_pids" ]]; then
        echo "    ollama runner : (not running)"
    else
        while read -r pid; do
            local cpu mem elapsed_s
            cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ' || echo "?")
            mem=$(ps -p "$pid" -o %mem= 2>/dev/null | tr -d ' ' || echo "?")
            elapsed_s=$(ps -p "$pid" -o etimes= 2>/dev/null | tr -d ' ' || echo "0")
            local elapsed_fmt
            elapsed_fmt=$(printf '%02d:%02d:%02d' \
                $((elapsed_s/3600)) $(( (elapsed_s%3600)/60 )) $((elapsed_s%60)))
            echo "    runner PID $pid  cpu: ${cpu}%  mem: ${mem}%  up: $elapsed_fmt"
            runner_cpu="${cpu%%.*}"  # integer part for heuristic
        done <<< "$runner_pids"
    fi

    # Pending /api/generate connections (clients waiting for response)
    local pending_reqs
    pending_reqs=$(ps aux 2>/dev/null \
        | grep -c 'curl.*api/generate' \
        | grep -v grep || true)
    pending_reqs=$(ps aux | grep 'api/generate' | grep -vc grep || echo 0)
    echo "    pending requests : $pending_reqs  (curl clients blocked on /api/generate)"

    echo ""

    # --- Ollama service status ---
    local svc_status
    svc_status=$(systemctl is-active ollama 2>/dev/null || echo "unknown")
    echo "  SERVICE   : ollama.service is $svc_status"

    echo ""

    # --- Stuck heuristic ---
    if [[ "$count" -gt 0 && -n "${runner_pids:-}" ]]; then
        local runner_elapsed
        runner_elapsed=$(ps -p "$(echo "$runner_pids" | head -1)" -o etimes= 2>/dev/null \
            | tr -d ' ' || echo 0)

        local gpu_low=0
        [[ "${total_gpu_util:-100}" -le "$STUCK_GPU_THRESHOLD" ]] && gpu_low=1

        if [[ "$gpu_low" -eq 1 && "$pending_reqs" -gt 0 && "$runner_elapsed" -ge "$STUCK_MIN_ELAPSED" ]]; then
            echo "  ⚠ POSSIBLY STUCK: GPU util=${total_gpu_util}% with $pending_reqs pending request(s)."
            echo "    Model has been loaded ${runner_elapsed}s. Consider: ./reset.sh --unload or --restart"
        else
            local reason=""
            [[ "$gpu_low" -eq 0 ]] && reason="GPU active (${total_gpu_util}%)"
            [[ "$pending_reqs" -eq 0 ]] && reason="no pending requests"
            [[ "$runner_elapsed" -lt "$STUCK_MIN_ELAPSED" ]] && \
                reason="$reason (runner only up ${runner_elapsed}s, below ${STUCK_MIN_ELAPSED}s threshold)"
            echo "  ✓ Status: generating or idle-warm  [$reason]"
        fi
    elif [[ "$count" -eq 0 ]]; then
        echo "  ✓ Status: no model loaded"
    fi

    echo ""
}

if [[ "$WATCH" -eq 1 ]]; then
    while true; do
        clear
        snapshot
        sleep "$INTERVAL"
    done
else
    snapshot
fi
