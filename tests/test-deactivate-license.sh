#!/usr/bin/env bash
# ============================================================================
# test-deactivate-license.sh - run scripts/deactivate-license.py against
# a mock Pexip Management API and assert that checking and deactivating
# behaves correctly.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORK="$(mktemp -d)"
MOCK_PID=""

cleanup() {
  [[ -n "$MOCK_PID" ]] && kill "$MOCK_PID" 2>/dev/null && wait "$MOCK_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

PORT=18446
MOCK_URL="https://127.0.0.1:${PORT}"
RECORDINGS="${WORK}/requests.jsonl"

for cmd in python3 curl jq openssl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "FAIL: '$cmd' is required to run this test" >&2
    exit 1
  fi
done

# ----------------------------------------------------------------------------
# Generate mock certificates and state file
# ----------------------------------------------------------------------------
echo "==> generating self-signed certificate for HTTPS mock"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "${WORK}/mock.key" -out "${WORK}/mock.crt" \
  -subj "/CN=127.0.0.1" 2>/dev/null

STATE_FILE="${WORK}/state.json"
cat << 'EOF' > "$STATE_FILE"
{
  "licence": [
    {
      "id": 1,
      "entitlement_id": "TEST-LICENSE-1",
      "description": "Mock Active License 1",
      "resource_uri": "/api/admin/configuration/v1/licence/1/"
    },
    {
      "id": 2,
      "entitlement_id": "TEST-LICENSE-2",
      "description": "Mock Active License 2",
      "resource_uri": "/api/admin/configuration/v1/licence/2/"
    }
  ],
  "_next_id": {
    "licence": 3
  }
}
EOF

# ----------------------------------------------------------------------------
# Start mock server
# ----------------------------------------------------------------------------
echo "==> starting mock Pexip on port ${PORT}"
python3 "${SCRIPT_DIR}/mock-pexip.py" \
  --port "$PORT" \
  --recordings-dir "$WORK" \
  --state-file "$STATE_FILE" \
  --cert "${WORK}/mock.crt" \
  --key "${WORK}/mock.key" \
  >"${WORK}/mock.stdout" 2>"${WORK}/mock.stderr" &
MOCK_PID=$!

# Wait for it to come up (max 5s)
for i in $(seq 1 50); do
  if curl --silent --insecure --max-time 1 -u admin:test "${MOCK_URL}/api/admin/configuration/v1/management_vm/" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$MOCK_PID" 2>/dev/null; then
    echo "FAIL: mock server died on startup. stderr:" >&2
    cat "${WORK}/mock.stderr" >&2
    exit 1
  fi
  sleep 0.1
done
echo "  mock is up"

# Helper functions for assertions
pass()  { printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
fail()  { printf "  \033[31mFAIL\033[0m  %s\n" "$*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Test Case 1: Run license check (should detect active licenses, exit 10)
# ----------------------------------------------------------------------------
echo "==> Case 1: Check for active licenses"
set +e
python3 "${REPO_ROOT}/scripts/deactivate-license.py" --check --host "127.0.0.1:${PORT}" --password "test"
check_exit=$?
set -e

if [[ $check_exit -ne 10 ]]; then
  fail "Expected check to return exit code 10, got $check_exit"
fi
pass "Check correctly identified active licenses (exit code 10)"

# ----------------------------------------------------------------------------
# Test Case 2: Run license deactivation (should delete licenses, exit 0)
# ----------------------------------------------------------------------------
echo "==> Case 2: Deactivate active licenses"
set +e
python3 "${REPO_ROOT}/scripts/deactivate-license.py" --deactivate --host "127.0.0.1:${PORT}" --password "test"
deactivate_exit=$?
set -e

if [[ $deactivate_exit -ne 0 ]]; then
  fail "Expected deactivation to exit 0, got $deactivate_exit"
fi
pass "Licenses successfully deactivated (exit code 0)"

# ----------------------------------------------------------------------------
# Test Case 3: Run check again (should find no licenses, exit 0)
# ----------------------------------------------------------------------------
echo "==> Case 3: Check again after deactivation"
set +e
python3 "${REPO_ROOT}/scripts/deactivate-license.py" --check --host "127.0.0.1:${PORT}" --password "test"
recheck_exit=$?
set -e

if [[ $recheck_exit -ne 0 ]]; then
  fail "Expected check to return exit code 0 after deactivation, got $recheck_exit"
fi
pass "Check returned exit code 0 when no licenses remain"

# ----------------------------------------------------------------------------
# Test Case 4: Offline scenario check (should skip check, exit 0)
# ----------------------------------------------------------------------------
echo "==> Case 4: Check against an offline port"
set +e
# Use a port we know is not listening
python3 "${REPO_ROOT}/scripts/deactivate-license.py" --check --host "127.0.0.1:18449" --password "test"
offline_exit=$?
set -e

if [[ $offline_exit -ne 0 ]]; then
  fail "Expected offline check to skip and return exit code 0, got $offline_exit"
fi
pass "Offline check gracefully skipped (exit code 0)"

echo "All deactivate-license assertions passed successfully."
exit 0
