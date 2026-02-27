#!/usr/bin/env bash
# TaskCompleted hook — runs the test suite for the project.
# Blocks completion (exit 2) if tests fail. Stderr goes to Claude as feedback.

set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_DIR"

FAILURES=()

# Run tests
if ! bundle exec rspec 2>&1; then
  FAILURES+=("Tests failed: bundle exec rspec")
fi


if [ ${#FAILURES[@]} -gt 0 ]; then
  echo "Checks failed. Fix before completing:" >&2
  for f in "${FAILURES[@]}"; do
    echo "  - $f" >&2
  done
  exit 2
fi

exit 0
