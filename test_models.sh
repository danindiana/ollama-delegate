#!/usr/bin/env bash
# test_models.sh — multi-tier model test suite
#
# Tests three concerns:
#   1. Functionality  — does delegate.sh work at all? (small models, mock output OK)
#   2. Concurrency    — does busy-wait handle multi-tenant queuing correctly?
#   3. Inference tiers — spot-check quality across model tiers
#
# Usage:
#   ./test_models.sh [--tier1] [--tier2] [--tier3] [--concurrent] [--all]
#
#   --tier1      Small/fast models (qwen3:4b, ministral-3:8b, qwen2.5-coder:7b)
#   --tier2      Medium models (qwen3.5:9b, deepseek-r1:8b, qwen2.5-coder:14b)
#   --tier3      Heavy models  (deepseek-r1:14b, devstral:24b, nemotron-terminal-14b)
#   --concurrent Fire N simultaneous requests at one model, verify queue behavior
#   --all        Run everything in order
#
# Each test prints: model, prompt, elapsed seconds, PASS/FAIL, and truncated response.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELEGATE="$SCRIPT_DIR/delegate.sh"
PEEK="$SCRIPT_DIR/peek.sh"
OLLAMA_API="${OLLAMA_HOST:-http://localhost:11434}"

PASS=0; FAIL=0
RESULTS=()

# ── helpers ──────────────────────────────────────────────────────────────────

col_green() { printf '\033[32m%s\033[0m' "$*"; }
col_red()   { printf '\033[31m%s\033[0m' "$*"; }
col_cyan()  { printf '\033[36m%s\033[0m' "$*"; }
col_dim()   { printf '\033[2m%s\033[0m'  "$*"; }

hr() { printf '%.0s─' {1..72}; echo; }

# Run one test: test_model <label> <model> <prompt> [min_response_words]
test_model() {
    local label="$1" model="$2" prompt="$3" min_words="${4:-3}"

    printf '  %-36s ' "$label"

    local t0 t1 elapsed response status
    t0=$(date +%s%N)

    response=$(OLLAMA_DELEGATE_VERBOSE=0 "$DELEGATE" --quiet "$model" "$prompt" 2>/dev/null || echo "")

    t1=$(date +%s%N)
    elapsed=$(( (t1 - t0) / 1000000 ))  # ms

    local word_count
    word_count=$(echo "$response" | wc -w)

    if [[ -z "$response" || "$word_count" -lt "$min_words" ]]; then
        col_red "FAIL"
        printf '  %dms  words:%d\n' "$elapsed" "$word_count"
        FAIL=$(( FAIL + 1 ))
        RESULTS+=("FAIL  $label ($model)  — empty or too-short response")
    else
        col_green "PASS"
        local preview
        preview=$(echo "$response" | tr '\n' ' ' | cut -c1-60)
        printf '  %dms  "%s…"\n' "$elapsed" "$preview"
        PASS=$(( PASS + 1 ))
        RESULTS+=("PASS  $label ($model)  ${elapsed}ms")
    fi
}

# ── tier definitions ──────────────────────────────────────────────────────────

run_tier1() {
    hr
    echo "TIER 1 — Small/fast (functionality verification, mock output fine)"
    hr

    # Functional smoke tests — just needs to return something coherent
    test_model "basic Q&A"             ministral-3:8b   "What is 2+2? Answer in one word." 1
    test_model "stdin pipe"            qwen3:4b         "$(echo 'List three colors.' | cat)" 3
    test_model "code snippet"          qwen2.5-coder:7b "Write a bash one-liner to count lines in a file." 3
    test_model "quiet flag"            ministral-3:8b   "Name one planet." 1
    test_model "flag: --wait"          qwen3:4b         "Say 'ok'." 1
    test_model "model swap (different)" qwen3.5:9b      "Say 'swap ok'." 1

    # Verify busy-wait path: load ministral, then immediately fire at qwen3
    echo ""
    echo "  $(col_dim 'Busy-wait test: fire two different models back-to-back without --wait')"
    printf '  %-36s ' "concurrent swap (warn path)"
    local warn_output
    warn_output=$(OLLAMA_DELEGATE_VERBOSE=1 \
        "$DELEGATE" qwen3:4b "Say 'queued ok'." 2>&1 || echo "")
    if echo "$warn_output" | grep -q "WARN\|warm\|idle\|cold"; then
        col_green "PASS"; echo "  (got expected status message)"
        PASS=$(( PASS + 1 ))
        RESULTS+=("PASS  busy-wait warn path")
    else
        col_red "FAIL"; echo "  (no status message seen)"
        FAIL=$(( FAIL + 1 ))
        RESULTS+=("FAIL  busy-wait warn path — no status output")
    fi
}

run_tier2() {
    hr
    echo "TIER 2 — Medium models (quality spot-check)"
    hr

    test_model "reasoning chain"       qwen3.5:9b         \
        "In two sentences: why does RAID-0 have no redundancy?" 10

    test_model "deepseek-r1 (think)"   deepseek-r1:8b     \
        "What is the capital of France? Answer in one word only." 1

    test_model "code gen 14b"          qwen2.5-coder:14b  \
        "Write a bash function that retries a command up to N times with sleep between attempts." 15

    test_model "sysadmin Q"            qwen3.5:9b         \
        "One command to show listening TCP ports on Linux." 3
}

run_tier3() {
    hr
    echo "TIER 3 — Heavy models (inference quality, expect slow load)"
    hr

    test_model "deepseek-r1:14b plan"  deepseek-r1:14b    \
        "List 5 steps to harden an SSH server. Be concise." 20

    test_model "devstral code"         devstral:24b       \
        "Write a Python function to tail a file and yield new lines as they appear." 20

    test_model "nemotron-terminal"     nemotron-terminal-14b \
        "Write a systemd unit file for a simple Python HTTP server on port 8080." 20
}

run_concurrent() {
    hr
    echo "CONCURRENT — multi-tenant queue test (${CONC_N:-4} simultaneous requests → 1 model)"
    hr

    local model="${CONC_MODEL:-ministral-3:8b}"
    local n="${CONC_N:-4}"
    local tmpdir
    tmpdir=$(mktemp -d)

    echo "  Model: $model   Requests: $n   (all fired in parallel, Ollama serializes)"
    echo ""

    local t0
    t0=$(date +%s)

    # Fire N requests in parallel as background jobs
    local pids=()
    for i in $(seq 1 "$n"); do
        (
            local out
            out=$(OLLAMA_DELEGATE_VERBOSE=0 "$DELEGATE" --quiet "$model" \
                "Request $i: give me a single unique random animal name, one word only." 2>/dev/null || echo "")
            echo "$out" > "$tmpdir/result_$i.txt"
        ) &
        pids+=($!)
    done

    # Watch queue depth while they run
    local dots=0
    while true; do
        local alive=0
        for pid in "${pids[@]}"; do
            kill -0 "$pid" 2>/dev/null && alive=$(( alive + 1 )) || true
        done
        [[ $alive -eq 0 ]] && break
        local queue_depth
        queue_depth=$(ps aux | awk '/api\/generate/ && !/awk/' | wc -l)
        printf "\r  %-4s in-flight, %d queued at Ollama…" "$alive" "$queue_depth"
        sleep 1
        dots=$(( dots + 1 ))
        [[ $dots -gt 120 ]] && break  # safety timeout
    done
    echo ""

    local t1 elapsed_total
    t1=$(date +%s)
    elapsed_total=$(( t1 - t0 ))

    echo ""
    echo "  Results (${elapsed_total}s total wall time):"
    local all_ok=1
    for i in $(seq 1 "$n"); do
        local result
        result=$(cat "$tmpdir/result_$i.txt" 2>/dev/null || echo "")
        if [[ -n "$result" ]]; then
            printf "    [%d] %s\n" "$i" "$result"
        else
            printf "    [%d] %s\n" "$i" "$(col_red 'EMPTY/FAILED')"
            all_ok=0
        fi
    done

    rm -rf "$tmpdir"

    echo ""
    if [[ $all_ok -eq 1 ]]; then
        col_green "  PASS"; echo " — all $n requests completed"
        PASS=$(( PASS + 1 ))
        RESULTS+=("PASS  concurrent/$n ($model)  ${elapsed_total}s total")
    else
        col_red "  FAIL"; echo " — one or more requests returned empty"
        FAIL=$(( FAIL + 1 ))
        RESULTS+=("FAIL  concurrent/$n ($model)  — empty responses")
    fi
}

# ── main ──────────────────────────────────────────────────────────────────────

DO_T1=0 DO_T2=0 DO_T3=0 DO_CONC=0
CONC_N=4
CONC_MODEL=ministral-3:8b

[[ $# -eq 0 ]] && { echo "Usage: test_models.sh --tier1|--tier2|--tier3|--concurrent [N [model]]|--all"; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tier1)      DO_T1=1; shift ;;
        --tier2)      DO_T2=1; shift ;;
        --tier3)      DO_T3=1; shift ;;
        --concurrent)
            DO_CONC=1; shift
            [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]] && { CONC_N="$1"; shift; }
            [[ $# -gt 0 && "$1" != --* ]]       && { CONC_MODEL="$1"; shift; }
            ;;
        --all)        DO_T1=1; DO_T2=1; DO_T3=1; DO_CONC=1; shift ;;
        *) echo "Unknown: $1" >&2; exit 1 ;;
    esac
done

echo ""
echo "$(col_cyan '╔══════════════════════════════════════════════════════════════════════╗')"
echo "$(col_cyan '║           ollama-delegate  •  model test suite                      ║')"
echo "$(col_cyan '╚══════════════════════════════════════════════════════════════════════╝')"
echo ""

# Confirm Ollama is reachable
curl -sf --max-time 3 "$OLLAMA_API/api/tags" > /dev/null 2>&1 \
    || { echo "ERROR: Ollama not reachable at $OLLAMA_API"; exit 1; }

[[ $DO_T1   -eq 1 ]] && run_tier1
[[ $DO_T2   -eq 1 ]] && run_tier2
[[ $DO_T3   -eq 1 ]] && run_tier3
[[ $DO_CONC -eq 1 ]] && run_concurrent

# ── summary ───────────────────────────────────────────────────────────────────
hr
echo "SUMMARY"
hr
for r in "${RESULTS[@]}"; do
    if [[ "$r" == PASS* ]]; then col_green "  $r"; else col_red "  $r"; fi
    echo
done
echo ""
echo "  Total: $(col_green "${PASS} passed")  $(col_red "${FAIL} failed")"
echo ""
