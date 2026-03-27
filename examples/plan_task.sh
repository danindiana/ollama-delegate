#!/usr/bin/env bash
# Get a reasoning scaffold from a local model before Claude acts on a task.
# Usage: plan_task.sh "describe the task"

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELEGATE="$SCRIPT_DIR/../delegate.sh"

TASK="${1:?Provide a task description}"

echo "=== Planning: $TASK ===" >&2

"$DELEGATE" deepseek-r1:14b \
"You are a technical planning assistant. Produce a concise numbered step-by-step plan for the following task. Be specific, actionable, and brief — no preamble or conclusion.

Task: $TASK"
