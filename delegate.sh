#!/usr/bin/env bash
# ollama-delegate — send a prompt to a local Ollama model with graceful busy-wait
#
# Handles the OLLAMA_MAX_LOADED_MODELS=1 constraint: detects what is currently
# loaded, distinguishes idle-warm from actively-generating, and either proceeds
# immediately or waits before forcing a model swap.
#
# Usage:
#   delegate.sh [--wait] [--max-wait N] <model> <prompt>
#   echo "prompt" | delegate.sh [--wait] [--max-wait N] <model> -
#
# Flags:
#   --wait          Block until Ollama is fully idle before sending (avoids
#                   interrupting another active generation at the cost of latency)
#   --max-wait N    Max seconds to wait when --wait is set (default: 300)
#   --quiet         Suppress status messages (only emit model response on stdout)
#
# Examples:
#   delegate.sh deepseek-r1:14b "Plan a Postgres schema migration"
#   echo "Summarize this log" | delegate.sh --wait qwen3.5:9b -
#   delegate.sh --wait --max-wait 120 nemotron-terminal-14b "How do I check RAID health?"

set -euo pipefail

# --- dependency check ---
for _cmd in curl jq date sed; do
    command -v "$_cmd" &>/dev/null || { echo "[ollama-delegate] ERROR: '$_cmd' not found in PATH" >&2; exit 1; }
done
unset _cmd

OLLAMA_API="${OLLAMA_HOST:-http://localhost:11434}"
# Keep-alive configured on this host via systemd override
KEEP_ALIVE_SECONDS=300   # OLLAMA_KEEP_ALIVE=5m
# If expires_at is within this many seconds of keep-alive from now,
# we treat the model as actively generating (expires_at was recently reset).
ACTIVE_THRESHOLD=30
POLL_INTERVAL=5

DO_WAIT=0
MAX_WAIT=300
QUIET=0

log()  { [[ "$QUIET" == "0" ]] && echo "[ollama-delegate] $*" >&2 || true; }
warn() { echo "[ollama-delegate] WARN: $*" >&2; }
err()  { echo "[ollama-delegate] ERROR: $*" >&2; exit 1; }

# --- parse flags ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --wait)      DO_WAIT=1; shift ;;
        --max-wait)  MAX_WAIT="${2:?--max-wait requires a value}"; shift 2 ;;
        --quiet)     QUIET=1; shift ;;
        --)          shift; break ;;
        -*)          err "Unknown flag: $1" ;;
        *)           break ;;
    esac
done

MODEL="${1:?Usage: delegate.sh [--wait] [--max-wait N] [--quiet] <model> <prompt|->}"
PROMPT_ARG="${2:?Prompt or '-' for stdin required}"

if [[ "$PROMPT_ARG" == "-" ]]; then
    PROMPT="$(cat)"
else
    PROMPT="$PROMPT_ARG"
fi

[[ -z "$PROMPT" ]] && err "Empty prompt"

# Guard against payloads that will silently fail due to shell quoting limits
# or Ollama context overflow. Warn loudly; operator can override with --force.
PROMPT_BYTES=$(printf '%s' "$PROMPT" | wc -c)
MAX_PROMPT_BYTES="${OLLAMA_DELEGATE_MAX_BYTES:-65536}"  # ~16k tokens, configurable
if [[ "$PROMPT_BYTES" -gt "$MAX_PROMPT_BYTES" ]]; then
    err "Prompt is ${PROMPT_BYTES} bytes (limit: ${MAX_PROMPT_BYTES}). " \
        "Set OLLAMA_DELEGATE_MAX_BYTES=N to raise, or pipe a shorter input. " \
        "Large inline prompts can silently produce empty responses."
fi

# --- connectivity ---
if ! curl -sf --max-time 3 "$OLLAMA_API/api/tags" > /dev/null 2>&1; then
    err "Ollama not reachable at $OLLAMA_API — is the service running?"
fi

# --- inspect /api/ps ---
get_ps() {
    curl -sf --max-time 5 "$OLLAMA_API/api/ps" 2>/dev/null || echo '{"models":[]}'
}

# Returns seconds until the loaded model's keep-alive expires (negative = expired)
seconds_until_expiry() {
    local expires_at="$1"
    local now_epoch expires_epoch
    now_epoch=$(date +%s)
    # expires_at is RFC3339 e.g. "2026-03-27T18:23:11.398795455-05:00"
    # Strip nanoseconds for `date` compatibility
    local expires_trimmed
    expires_trimmed=$(echo "$expires_at" | sed 's/\(\.[0-9]*\)\([-+]\)/\2/')
    expires_epoch=$(date -d "$expires_trimmed" +%s 2>/dev/null || echo "$now_epoch")
    echo $((expires_epoch - now_epoch))
}

# Determine if a model appears to be actively generating
# (its expires_at was reset recently — within ACTIVE_THRESHOLD of full keep-alive)
is_likely_generating() {
    local expires_at="$1"
    local secs_left
    secs_left=$(seconds_until_expiry "$expires_at")
    # Negative means keep-alive already lapsed — model is held by an active request
    # but the timer has expired. Treat as generating (don't force a swap).
    [[ $secs_left -lt 0 ]] && return 0
    # If secs_left is close to full KEEP_ALIVE, the timer was recently reset → generating
    local time_since_reset=$(( KEEP_ALIVE_SECONDS - secs_left ))
    [[ $time_since_reset -le $ACTIVE_THRESHOLD ]]
}

# --- main logic ---
PS_JSON=$(get_ps)
COUNT=$(echo "$PS_JSON" | jq -r '.models | length' 2>/dev/null || echo 0)

if [[ "$COUNT" -eq 0 ]]; then
    log "No model loaded — cold start for $MODEL"

elif [[ "$(echo "$PS_JSON" | jq -r '.models[0].name')" == "$MODEL" ]]; then
    log "Warm hit — $MODEL already loaded, sending immediately"

else
    LOADED_NAME=$(echo "$PS_JSON" | jq -r '.models[0].name')
    LOADED_SIZE=$(echo "$PS_JSON" | jq -r '.models[0].size_vram // "?"')
    EXPIRES_AT=$(echo "$PS_JSON" | jq -r '.models[0].expires_at')
    SECS_LEFT=$(seconds_until_expiry "$EXPIRES_AT")

    if is_likely_generating "$EXPIRES_AT"; then
        STATUS="ACTIVE (expires_at just reset — likely generating)"
    else
        STATUS="IDLE-WARM (expires in ~${SECS_LEFT}s)"
    fi

    if [[ "$DO_WAIT" == "1" ]]; then
        log "Different model loaded: '$LOADED_NAME' ($STATUS, vram: $LOADED_SIZE)"
        log "--wait set — blocking until Ollama is idle (max ${MAX_WAIT}s)"
        elapsed=0
        while true; do
            PS_JSON=$(get_ps)
            COUNT=$(echo "$PS_JSON" | jq -r '.models | length' 2>/dev/null || echo 0)
            [[ "$COUNT" -eq 0 ]] && break

            LOADED_NAME=$(echo "$PS_JSON" | jq -r '.models[0].name')
            EXPIRES_AT=$(echo "$PS_JSON" | jq -r '.models[0].expires_at')
            SECS_LEFT=$(seconds_until_expiry "$EXPIRES_AT")
            log "Waiting — '$LOADED_NAME' active, expires in ~${SECS_LEFT}s (${elapsed}s elapsed)"

            [[ $elapsed -ge $MAX_WAIT ]] && \
                err "Timed out after ${MAX_WAIT}s waiting for Ollama to be idle. Still loaded: $LOADED_NAME"

            sleep "$POLL_INTERVAL"
            elapsed=$((elapsed + POLL_INTERVAL))
        done
        log "Ollama is now idle — submitting to $MODEL"
    else
        warn "Different model '$LOADED_NAME' is loaded ($STATUS). Ollama will swap on completion."
        warn "Use --wait to block until idle. Sending now and queuing request."
    fi
fi

log "Submitting prompt to $MODEL..."

PAYLOAD=$(jq -n \
    --arg model "$MODEL" \
    --arg prompt "$PROMPT" \
    '{model: $model, prompt: $prompt, stream: false, options: {temperature: 0.3}}')

RESPONSE=$(curl -sf --max-time 600 "$OLLAMA_API/api/generate" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")

[[ -z "$RESPONSE" ]] && err "Empty response from Ollama (model: $MODEL may have failed to load)"

echo "$RESPONSE" | jq -r '.response'
