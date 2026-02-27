#!/usr/bin/env bash
# PostToolUse hook for Edit|Write — runs the appropriate linter/formatter on the changed file.
# Receives JSON on stdin with tool_input.file_path.
# Exits 0 always (non-blocking) — linting feedback is advisory.

set -euo pipefail

INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

[ -z "$FILE" ] && exit 0
[ ! -f "$FILE" ] && exit 0

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

case "$FILE" in
  *.rb)
    cd "$PROJECT_DIR"
    bundle exec rubocop -A "$FILE" > /dev/null 2>&1 || true
    ;;
esac

exit 0
