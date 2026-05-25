#!/usr/bin/env bash
# ============================================================================
# test-register-conf-nodes.sh - run scripts/register-conf-nodes.sh against
# a mock Pexip Management API and assert that worker_vm POST requests carry
# the correct fields (including static_nat_address when present).
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

PORT=18445
MOCK_URL="http://127.0.0.1:${PORT}"
RECORDINGS="${WORK}/requests.jsonl"

for cmd in python3 curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "FAIL: '$cmd' is required to run this test" >&2
    exit 1
  fi
done

echo "==> starting mock Pexip on port ${PORT}"
python3 "${SCRIPT_DIR}/mock-pexip.py" \
  --port "$PORT" \
  --recordings-dir "$WORK" \
  >"${WORK}/mock.stdout" 2>"${WORK}/mock.stderr" &
MOCK_PID=$!

# Wait for it to come up (max 5s)
for i in $(seq 1 50); do
  if curl --silent --max-time 1 -u admin:test "${MOCK_URL}/api/admin/configuration/v1/management_vm/" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

# ----------------------------------------------------------------------------
# Test Case 1: Register node WITHOUT static_nat_address
# ----------------------------------------------------------------------------
echo "==> Run 1: Register node WITHOUT static_nat_address"
: > "$RECORDINGS"

PEXIP_CONF_NODES_JSON_WITHOUT='[
  {
    "name": "pexip-conf-private-1",
    "hostname": "pexip-conf-private-1",
    "domain": "pexip.local",
    "address": "10.0.0.10",
    "netmask": "255.255.255.0",
    "gateway": "10.0.0.1",
    "password_hash": "mock-hash"
  }
]'

PEXIP_API_ROOT="${MOCK_URL}" \
PEXIP_MANAGER_IP="ignored" \
PEXIP_ADMIN_PASSWORD="test" \
PEXIP_CONF_NODES_JSON="$PEXIP_CONF_NODES_JSON_WITHOUT" \
PEXIP_OUT_DIR="$WORK" \
  "${REPO_ROOT}/scripts/register-conf-nodes.sh" > "${WORK}/run1.stdout" 2> "${WORK}/run1.stderr"

# Assertions
pass()  { printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
fail()  { printf "  \033[31mFAIL\033[0m  %s\n" "$*" >&2; echo "  Recordings:" >&2; cat "$RECORDINGS" >&2; exit 1; }

count_requests() {
  local method="$1" pattern="$2"
  jq -c --arg m "$method" --arg p "$pattern" \
    'select(.method == $m and (.path | test($p)))' "$RECORDINGS" | wc -l | tr -d ' '
}

body_of() {
  local method="$1" pattern="$2" n="$3"
  jq -rc --arg m "$method" --arg p "$pattern" \
    'select(.method == $m and (.path | test($p))) | .body' "$RECORDINGS" \
    | sed -n "${n}p"
}

n="$(count_requests POST '/worker_vm/?$')"
[[ "$n" == "1" ]] || fail "expected 1 POST to /worker_vm/, got $n"
body="$(body_of POST '/worker_vm/?$' 1)"
echo "$body" | jq -e 'has("static_nat_address") | not' >/dev/null \
  || fail "expected payload to omit static_nat_address, got: $body"
pass "omitted static_nat_address successfully when not specified"

# ----------------------------------------------------------------------------
# Test Case 2: Register node WITH static_nat_address
# ----------------------------------------------------------------------------
echo "==> Run 2: Register node WITH static_nat_address"
: > "$RECORDINGS"

PEXIP_CONF_NODES_JSON_WITH='[
  {
    "name": "pexip-conf-public-1",
    "hostname": "pexip-conf-public-1",
    "domain": "pexip.local",
    "address": "10.0.0.11",
    "netmask": "255.255.255.0",
    "gateway": "10.0.0.1",
    "password_hash": "mock-hash",
    "static_nat_address": "203.0.113.10"
  }
]'

PEXIP_API_ROOT="${MOCK_URL}" \
PEXIP_MANAGER_IP="ignored" \
PEXIP_ADMIN_PASSWORD="test" \
PEXIP_CONF_NODES_JSON="$PEXIP_CONF_NODES_JSON_WITH" \
PEXIP_OUT_DIR="$WORK" \
  "${REPO_ROOT}/scripts/register-conf-nodes.sh" > "${WORK}/run2.stdout" 2> "${WORK}/run2.stderr"

n="$(count_requests POST '/worker_vm/?$')"
[[ "$n" == "1" ]] || fail "expected 1 POST to /worker_vm/ for new node, got $n"
body="$(body_of POST '/worker_vm/?$' 1)"
echo "$body" | jq -e '.static_nat_address == "203.0.113.10"' >/dev/null \
  || fail "expected payload to have static_nat_address '203.0.113.10', got: $body"
pass "included static_nat_address successfully when specified"

echo "All register-conf-nodes assertions passed successfully."
exit 0
