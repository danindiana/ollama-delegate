#!/usr/bin/env bash
# Get a first-pass code draft from devstral before Claude refines it.
# Usage: draft_code.sh <language> "describe what to implement"

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELEGATE="$SCRIPT_DIR/../delegate.sh"

LANG="${1:?Provide a language (e.g. rust, python, bash)}"
SPEC="${2:?Provide an implementation description}"

"$DELEGATE" devstral:24b \
"Write a $LANG implementation for the following. Output only code with minimal inline comments. No markdown fences, no explanation outside the code.

Spec: $SPEC"
