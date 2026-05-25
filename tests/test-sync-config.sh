#!/usr/bin/env bash
# ============================================================================
# test-sync-config.sh - run scripts/sync-config.py against mock Pexip API
# and assert idempotency, correct POSTing, and PATCHing.
#
# Exit 0 = all assertions passed.
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

PORT=18444
MOCK_URL="https://127.0.0.1:${PORT}"
RECORDINGS="${WORK}/requests.jsonl"

# ----------------------------------------------------------------------------
# Sanity check tools
# ----------------------------------------------------------------------------
for cmd in python3 curl jq openssl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "FAIL: '$cmd' is required to run this test" >&2
    exit 1
  fi
done

# ----------------------------------------------------------------------------
# Generate mock certificates and start mock
# ----------------------------------------------------------------------------
echo "==> generating self-signed certificate for HTTPS mock"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "${WORK}/mock.key" -out "${WORK}/mock.crt" \
  -subj "/CN=127.0.0.1" 2>/dev/null

echo "==> starting mock Pexip on port ${PORT}"
python3 "${SCRIPT_DIR}/mock-pexip.py" \
  --port "$PORT" \
  --recordings-dir "$WORK" \
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

# ----------------------------------------------------------------------------
# Generate test config files
# ----------------------------------------------------------------------------
CONFIG_RUN1="${WORK}/config-run1.yaml"
CONFIG_RUN2="${WORK}/config-run2.yaml"
CONFIG_RUN3="${WORK}/config-run3.yaml"

cat << 'EOF' > "$CONFIG_RUN1"
license_key: "TEST-LICENSE-KEY-12345"

vmrs:
  - name: "test-vmr"
    description: "Initial VMR Description"
    tag: "test-tag"
    aliases:
      - "test-vmr@pexip.local"

gateway_rules:
  - name: "test-rule"
    description: "Initial Rule Description"
    priority: 100
    match_string: ".*"
    replace_string: "test-replace"
    outgoing_location: "Primary Location"

users:
  - primary_email_address: "test.user@pexip.local"
    first_name: "Test"
    last_name: "User"
    display_name: "Test User"
    telephone_number: "+15550100"
    department: "QA"

device_aliases:
  - device_alias: "test-device@pexip.local"
    device_description: "Initial Device Description"
    device_username: "test_device_user"
    device_password: "InitialPassword123!"
    device_tag: "test-device-tag"
    primary_owner_email_address: "test.user@pexip.local"
EOF

# Run 2 is identical to Run 1 for idempotency test
cp "$CONFIG_RUN1" "$CONFIG_RUN2"

# Run 3 modifies values to check updates (PATCH)
cat << 'EOF' > "$CONFIG_RUN3"
license_key: "TEST-LICENSE-KEY-12345"

vmrs:
  - name: "test-vmr"
    description: "Updated VMR Description"
    tag: "test-tag"
    aliases:
      - "test-vmr@pexip.local"

gateway_rules:
  - name: "test-rule"
    description: "Updated Rule Description"
    priority: 100
    match_string: ".*"
    replace_string: "test-replace"
    outgoing_location: "Primary Location"

users:
  - primary_email_address: "test.user@pexip.local"
    first_name: "Test"
    last_name: "User"
    display_name: "Updated Test User"
    telephone_number: "+15550100"
    department: "QA"

device_aliases:
  - device_alias: "test-device@pexip.local"
    device_description: "Updated Device Description"
    device_username: "test_device_user"
    device_password: "InitialPassword123!"
    device_tag: "updated-device-tag"
    primary_owner_email_address: "test.user@pexip.local"
EOF

TEST_SCRIPT="${REPO_ROOT}/scripts/sync-config.py"

# Helpers for assertions
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

# ----------------------------------------------------------------------------
# RUN 1: Fresh Import
# ----------------------------------------------------------------------------
echo "==> RUN 1: Initial Sync (Fresh State)"
: > "$RECORDINGS"

set +e
python3 "$TEST_SCRIPT" \
  --host "127.0.0.1:${PORT}" \
  --password "test" \
  --config "$CONFIG_RUN1" > "${WORK}/run1.stdout" 2> "${WORK}/run1.stderr"
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
  echo "FAIL: sync-config.py exited $rc on Run 1" >&2
  echo "--- stdout ---" >&2; cat "${WORK}/run1.stdout" >&2
  echo "--- stderr ---" >&2; cat "${WORK}/run1.stderr" >&2
  exit 1
fi

echo "==> Assertions for RUN 1"

# License POST
n="$(count_requests POST '/licence/?$')"
[[ "$n" == "1" ]] || fail "expected 1 POST to /licence/, got $n"
body="$(body_of POST '/licence/?$' 1)"
echo "$body" | jq -e '.entitlement_id == "TEST-LICENSE-KEY-12345"' >/dev/null || fail "incorrect license POST payload"
pass "License was correctly POSTed"

# VMR POST
n="$(count_requests POST '/conference/?$')"
[[ "$n" == "1" ]] || fail "expected 1 POST to /conference/, got $n"
body="$(body_of POST '/conference/?$' 1)"
echo "$body" | jq -e '.name == "test-vmr" and .description == "Initial VMR Description"' >/dev/null || fail "incorrect VMR POST payload"
pass "VMR was correctly POSTed"

# Gateway Rule POST
n="$(count_requests POST '/gateway_routing_rule/?$')"
[[ "$n" == "1" ]] || fail "expected 1 POST to /gateway_routing_rule/, got $n"
body="$(body_of POST '/gateway_routing_rule/?$' 1)"
echo "$body" | jq -e '.name == "test-rule" and .description == "Initial Rule Description"' >/dev/null || fail "incorrect gateway rule POST payload"
pass "Gateway Rule was correctly POSTed"

# User POST
n="$(count_requests POST '/end_user/?$')"
[[ "$n" == "1" ]] || fail "expected 1 POST to /end_user/, got $n"
body="$(body_of POST '/end_user/?$' 1)"
echo "$body" | jq -e '.primary_email_address == "test.user@pexip.local" and .display_name == "Test User"' >/dev/null || fail "incorrect user POST payload"
pass "End User was correctly POSTed"

# Device POST
n="$(count_requests POST '/device/?$')"
[[ "$n" == "1" ]] || fail "expected 1 POST to /device/, got $n"
body="$(body_of POST '/device/?$' 1)"
echo "$body" | jq -e '.alias == "test-device@pexip.local" and .password == "InitialPassword123!"' >/dev/null || fail "incorrect device POST payload"
pass "Device Alias was correctly POSTed"


# ----------------------------------------------------------------------------
# RUN 2: Idempotency Check (No modifications)
# ----------------------------------------------------------------------------
echo "==> RUN 2: Idempotency Sync (No-Op)"
: > "$RECORDINGS"

set +e
python3 "$TEST_SCRIPT" \
  --host "127.0.0.1:${PORT}" \
  --password "test" \
  --config "$CONFIG_RUN2" > "${WORK}/run2.stdout" 2> "${WORK}/run2.stderr"
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
  echo "FAIL: sync-config.py exited $rc on Run 2" >&2
  echo "--- stdout ---" >&2; cat "${WORK}/run2.stdout" >&2
  echo "--- stderr ---" >&2; cat "${WORK}/run2.stderr" >&2
  exit 1
fi

echo "==> Assertions for RUN 2"

# No POSTs
n="$(count_requests POST '/(licence|conference|gateway_routing_rule|end_user|device)/?$')"
[[ "$n" == "0" ]] || fail "expected 0 POSTs, got $n"
pass "No new creations (POSTs) triggered"

# No PATCHes
n="$(count_requests PATCH '/(conference|gateway_routing_rule|end_user|device)/[0-9]+/?$')"
[[ "$n" == "0" ]] || fail "expected 0 PATCHes, got $n"
pass "No updates (PATCHes) triggered"


# ----------------------------------------------------------------------------
# RUN 3: Updates Check (Modifications)
# ----------------------------------------------------------------------------
echo "==> RUN 3: Update Sync (PATCH verification)"
: > "$RECORDINGS"

set +e
python3 "$TEST_SCRIPT" \
  --host "127.0.0.1:${PORT}" \
  --password "test" \
  --config "$CONFIG_RUN3" > "${WORK}/run3.stdout" 2> "${WORK}/run3.stderr"
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
  echo "FAIL: sync-config.py exited $rc on Run 3" >&2
  echo "--- stdout ---" >&2; cat "${WORK}/run3.stdout" >&2
  echo "--- stderr ---" >&2; cat "${WORK}/run3.stderr" >&2
  exit 1
fi

echo "==> Assertions for RUN 3"

# No POSTs
n="$(count_requests POST '/(licence|conference|gateway_routing_rule|end_user|device)/?$')"
[[ "$n" == "0" ]] || fail "expected 0 POSTs, got $n"
pass "No creations triggered during update run"

# VMR PATCH
n="$(count_requests PATCH '/conference/1/?$')"
[[ "$n" == "1" ]] || fail "expected 1 PATCH to /conference/1/, got $n"
body="$(body_of PATCH '/conference/1/?$' 1)"
echo "$body" | jq -e '.description == "Updated VMR Description"' >/dev/null || fail "incorrect VMR PATCH payload: $body"
pass "VMR was correctly updated (PATCH)"

# Gateway Rule PATCH
n="$(count_requests PATCH '/gateway_routing_rule/1/?$')"
[[ "$n" == "1" ]] || fail "expected 1 PATCH to /gateway_routing_rule/1/, got $n"
body="$(body_of PATCH '/gateway_routing_rule/1/?$' 1)"
echo "$body" | jq -e '.description == "Updated Rule Description"' >/dev/null || fail "incorrect gateway rule PATCH payload: $body"
pass "Gateway Rule was correctly updated (PATCH)"

# User PATCH
n="$(count_requests PATCH '/end_user/1/?$')"
[[ "$n" == "1" ]] || fail "expected 1 PATCH to /end_user/1/, got $n"
body="$(body_of PATCH '/end_user/1/?$' 1)"
echo "$body" | jq -e '.display_name == "Updated Test User"' >/dev/null || fail "incorrect user PATCH payload: $body"
pass "End User was correctly updated (PATCH)"

# Device PATCH (must include password when updating other fields)
n="$(count_requests PATCH '/device/1/?$')"
[[ "$n" == "1" ]] || fail "expected 1 PATCH to /device/1/, got $n"
body="$(body_of PATCH '/device/1/?$' 1)"
echo "$body" | jq -e '.description == "Updated Device Description" and .tag == "updated-device-tag" and .password == "InitialPassword123!"' >/dev/null || fail "incorrect device PATCH payload: $body"
pass "Device Alias was correctly updated (PATCH, including password)"


# ----------------------------------------------------------------------------
# RUN 4: Unlicensed Node Sync
# ----------------------------------------------------------------------------
echo "==> Restarting mock Pexip to test Unlicensed Node Sync"
[[ -n "$MOCK_PID" ]] && kill "$MOCK_PID" 2>/dev/null && wait "$MOCK_PID" 2>/dev/null || true

# Start a fresh mock server (so it has no licenses)
: > "$RECORDINGS"
python3 "${SCRIPT_DIR}/mock-pexip.py" \
  --port "$PORT" \
  --recordings-dir "$WORK" \
  --cert "${WORK}/mock.crt" \
  --key "${WORK}/mock.key" \
  >"${WORK}/mock.stdout" 2>"${WORK}/mock.stderr" &
MOCK_PID=$!

# Wait for it to come up
for i in $(seq 1 50); do
  if curl --silent --insecure --max-time 1 -u admin:test "${MOCK_URL}/api/admin/configuration/v1/management_vm/" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

CONFIG_UNLICENSED="${WORK}/config-unlicensed.yaml"
cat << 'EOF' > "$CONFIG_UNLICENSED"
license_key: ""

vmrs:
  - name: "skipped-vmr"
    description: "Should be skipped because unlicensed"
    tag: "skipped"
    aliases:
      - "skipped@pexip.local"

gateway_rules:
  - name: "teams-rule"
    description: "Teams gateway rule (should be skipped)"
    priority: 100
    match_string: ".*"
    called_device_type: "teams_conference"
    outgoing_protocol: "teams"
  - name: "sip-rule"
    description: "Standard SIP rule (should NOT be skipped)"
    priority: 200
    match_string: ".*"
    called_device_type: "external"
    outgoing_protocol: "sip"
EOF

echo "==> RUN 4: Syncing unlicensed config"
set +e
python3 "$TEST_SCRIPT" \
  --host "127.0.0.1:${PORT}" \
  --password "test" \
  --config "$CONFIG_UNLICENSED" > "${WORK}/run4.stdout" 2> "${WORK}/run4.stderr"
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
  echo "FAIL: sync-config.py exited $rc on Run 4 (unlicensed)" >&2
  echo "--- stdout ---" >&2; cat "${WORK}/run4.stdout" >&2
  echo "--- stderr ---" >&2; cat "${WORK}/run4.stderr" >&2
  exit 1
fi

echo "==> Assertions for RUN 4"

# Ensure VMR conference was NOT POSTed
n="$(count_requests POST '/conference/?$')"
[[ "$n" == "0" ]] || fail "expected 0 POSTs to /conference/, got $n"
pass "VMR conference synchronization was skipped"

# Ensure only the non-Teams gateway rule (sip-rule) was POSTed, and teams-rule was skipped
n="$(count_requests POST '/gateway_routing_rule/?$')"
[[ "$n" == "1" ]] || fail "expected exactly 1 POST to /gateway_routing_rule/ (sip-rule), got $n"
body="$(body_of POST '/gateway_routing_rule/?$' 1)"
echo "$body" | jq -e '.name == "sip-rule"' >/dev/null || fail "expected 'sip-rule' to be POSTed, but got: $body"
pass "Teams-specific gateway rule was skipped, while standard SIP rule was synced"

echo
echo "All assertions passed successfully."
exit 0
