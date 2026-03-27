#!/usr/bin/env bash
# Compress a log file through a local model before Claude reads it.
# Reduces token cost when Claude needs to act on large log output.
# Usage: summarize_log.sh <logfile>   (or pipe: cat log | summarize_log.sh -)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELEGATE="$SCRIPT_DIR/../delegate.sh"

INPUT="${1:?Provide a log file path or '-' for stdin}"

if [[ "$INPUT" == "-" ]]; then
    LOG_CONTENT="$(cat)"
else
    [[ -f "$INPUT" ]] || { echo "File not found: $INPUT" >&2; exit 1; }
    LOG_CONTENT="$(cat "$INPUT")"
fi

PROMPT="Summarize the following log output. Focus on: errors, warnings, anomalies, repeated patterns, and any actionable issues. Be concise. Skip healthy/normal lines unless they provide context for an error.

---
$LOG_CONTENT
---"

echo "$PROMPT" | "$DELEGATE" --quiet ministral-3:8b -
