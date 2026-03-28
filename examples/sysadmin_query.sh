#!/usr/bin/env bash
# Ask nemotron-terminal (purpose-trained for shell/sysadmin) a quick question.
# Usage: sysadmin_query.sh "how do I check if a port is listening?"
#
# Note: nemotron-terminal-14b emits a <think> block before the answer.
# This script strips it. The model also loops on meta/abstract prompts —
# use deepseek-r1:14b for anything requiring reasoning about constraints.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELEGATE="$SCRIPT_DIR/../delegate.sh"

QUERY="${1:?Provide a sysadmin/shell question}"

"$DELEGATE" nemotron-terminal-14b \
"You are a Linux sysadmin expert. Answer this question concisely with the exact commands needed. No preamble.

Question: $QUERY" | awk '/<\/think>/{found=1; next} found'
