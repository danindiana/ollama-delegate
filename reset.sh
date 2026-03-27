#!/usr/bin/env bash
# reset.sh — recover Ollama from a stuck or wedged state
#
# Options (in order of aggression):
#   --unload <model>   Force-unload a specific model via API (keep_alive=0)
#                      Pending requests to that model will get an error response.
#   --unload-all       Unload every currently loaded model via API
#   --kill-runner      SIGTERM the ollama runner process (Ollama service stays up,
#                      runner restarts on next request)
#   --restart          sudo systemctl restart ollama  (nuclear — drops all connections)
#   --status           Just show current state, no action (same as peek.sh snapshot)
#
# Usage:
#   ./reset.sh --unload nemotron-terminal-14b:latest
#   ./reset.sh --unload-all
#   ./reset.sh --kill-runner
#   ./reset.sh --restart

set -euo pipefail

OLLAMA_API="${OLLAMA_HOST:-http://localhost:11434}"

err()  { echo "[reset] ERROR: $*" >&2; exit 1; }
log()  { echo "[reset] $*"; }
warn() { echo "[reset] WARN: $*" >&2; }

get_loaded_models() {
    curl -sf --max-time 3 "$OLLAMA_API/api/ps" 2>/dev/null \
        | jq -r '.models[].name' 2>/dev/null || true
}

force_unload_model() {
    local model="$1"
    log "Force-unloading '$model' via API (keep_alive=0)..."
    local resp
    resp=$(curl -sf --max-time 30 "$OLLAMA_API/api/generate" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg m "$model" \
            '{model:$m, prompt:"", keep_alive:0, stream:false}')" \
        2>/dev/null || echo "")

    # Small pause then verify
    sleep 2
    local still_loaded
    still_loaded=$(get_loaded_models | grep -c "^${model}$" || echo 0)
    if [[ "$still_loaded" -eq 0 ]]; then
        log "✓ '$model' unloaded successfully"
    else
        warn "'$model' still appears loaded — try --kill-runner or --restart"
    fi
}

[[ $# -eq 0 ]] && { echo "Usage: reset.sh --unload <model> | --unload-all | --kill-runner | --restart | --status"; exit 1; }

case "$1" in

    --unload)
        MODEL="${2:?--unload requires a model name (e.g. nemotron-terminal-14b:latest)}"
        # Verify it's actually loaded
        if ! get_loaded_models | grep -q "^${MODEL}$"; then
            warn "'$MODEL' is not currently loaded. Loaded models:"
            get_loaded_models | sed 's/^/  /' || echo "  (none)"
            exit 0
        fi
        force_unload_model "$MODEL"
        ;;

    --unload-all)
        log "Unloading all loaded models..."
        LOADED=$(get_loaded_models)
        if [[ -z "$LOADED" ]]; then
            log "No models currently loaded."
            exit 0
        fi
        while IFS= read -r m; do
            [[ -z "$m" ]] && continue
            force_unload_model "$m"
        done <<< "$LOADED"
        log "Done."
        ;;

    --kill-runner)
        log "Sending SIGTERM to ollama runner process(es)..."
        PIDS=$(pgrep -f 'ollama runner' 2>/dev/null || true)
        if [[ -z "$PIDS" ]]; then
            log "No ollama runner process found."
            exit 0
        fi
        while IFS= read -r pid; do
            [[ -z "$pid" ]] && continue
            log "  SIGTERM → PID $pid"
            sudo kill -TERM "$pid" 2>/dev/null || warn "Could not signal PID $pid (try running as root)"
        done <<< "$PIDS"
        sleep 2
        REMAINING=$(pgrep -f 'ollama runner' 2>/dev/null | wc -l || echo 0)
        if [[ "$REMAINING" -eq 0 ]]; then
            log "✓ Runner stopped. Will restart on next request."
        else
            warn "$REMAINING runner process(es) still alive. Try --restart."
        fi
        ;;

    --restart)
        log "Restarting ollama.service (all connections will drop)..."
        log "WARNING: any background delegate.sh calls will get empty responses and need re-running."
        read -rp "[reset] Confirm restart? [y/N] " yn
        [[ "${yn,,}" == "y" ]] || { log "Aborted."; exit 0; }
        sudo systemctl restart ollama
        sleep 3
        STATUS=$(systemctl is-active ollama 2>/dev/null || echo "unknown")
        log "✓ ollama.service is now: $STATUS"
        ;;

    --status)
        echo "=== Loaded models ==="
        get_loaded_models | sed 's/^/  /' || echo "  (none)"
        echo ""
        echo "=== GPU ==="
        nvidia-smi --query-gpu=index,utilization.gpu,memory.used,memory.total \
            --format=csv,noheader | sed 's/^/  GPU/' || echo "  nvidia-smi unavailable"
        echo ""
        echo "=== Runner processes ==="
        ps aux | grep 'ollama runner' | grep -v grep | \
            awk '{printf "  PID %-7s  cpu: %-5s  mem: %-5s  elapsed: %s\n", $2,$3,$4,$10}' \
            || echo "  (none)"
        ;;

    *)
        err "Unknown option: $1"
        ;;
esac
