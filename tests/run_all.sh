#!/usr/bin/env bash
# ============================================================================
# run_all.sh - runs all test-*.sh integration/unit tests in this directory.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILED_TESTS=()
PASSED_COUNT=0
FAILED_COUNT=0

echo "==> Running all test suites..."

for t_script in "$SCRIPT_DIR"/test-*.sh; do
  # Check if any matching files exist
  [ -f "$t_script" ] || continue

  t_name="$(basename "$t_script")"
  echo "------------------------------------------------------------"
  echo "Running $t_name..."
  echo "------------------------------------------------------------"

  if bash "$t_script"; then
    echo "==> PASS: $t_name"
    PASSED_COUNT=$((PASSED_COUNT + 1))
  else
    echo "==> FAIL: $t_name"
    FAILED_TESTS+=("$t_name")
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi
done

echo "------------------------------------------------------------"
echo "Summary: $PASSED_COUNT passed, $FAILED_COUNT failed."
if [ ${#FAILED_TESTS[@]} -ne 0 ]; then
  echo "Some tests failed:"
  for f in "${FAILED_TESTS[@]}"; do
    echo "  - $f"
  done
  exit 1
else
  echo "All tests passed successfully!"
  exit 0
fi
