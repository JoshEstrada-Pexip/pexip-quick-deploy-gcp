#!/usr/bin/env bash
# ============================================================================
# test-install-cert.sh - run scripts/install-cert.sh against a mock Pexip
# Management API and assert the requests look right.
#
# Catches: URI construction, basic-auth handling, PEM chain concatenation,
# FQDN-to-node-name mapping, idempotency on re-run, error handling.
#
# Does NOT catch: wrong field names in the cert upload payload (the mock
# accepts whatever - only a live Pexip Manager will reject bad fields).
# See memory/reference-pexip-api.md "Unverified" for the field-name list.
#
# Run from anywhere:
#   ./tests/test-install-cert.sh
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

PORT=18443  # avoid colliding with anything real
MOCK_URL="http://127.0.0.1:${PORT}"
RECORDINGS="${WORK}/requests.jsonl"

# ----------------------------------------------------------------------------
# Sanity check tools we need
# ----------------------------------------------------------------------------
for cmd in python3 curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "FAIL: '$cmd' is required to run this test" >&2
    exit 1
  fi
done

# ----------------------------------------------------------------------------
# Start the mock
# ----------------------------------------------------------------------------
echo "==> starting mock Pexip on port ${PORT}"
python3 "${SCRIPT_DIR}/mock-pexip.py" \
  --port "$PORT" \
  --recordings-dir "$WORK" \
  >"${WORK}/mock.stdout" 2>"${WORK}/mock.stderr" &
MOCK_PID=$!

# Wait for it to come up (max 5s).
for i in $(seq 1 50); do
  if curl --silent --max-time 1 -u admin:test "${MOCK_URL}/api/admin/configuration/v1/management_vm/" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$MOCK_PID" 2>/dev/null; then
    echo "FAIL: mock server died on startup. stderr:" >&2
    cat "${WORK}/mock.stderr" >&2
    exit 1
  fi
  sleep 0.1
done

# Quick assertion that the seed worked
if ! curl --silent -u admin:test "${MOCK_URL}/api/admin/configuration/v1/management_vm/" \
     | jq -e '.objects[0].name == "pexip-mgr"' >/dev/null; then
  echo "FAIL: mock didn't seed the management_vm record" >&2
  exit 1
fi
echo "  mock is up"

# ----------------------------------------------------------------------------
# Pre-register a conf node via the mock (simulates what register-conf-nodes.sh
# would have done in a real apply, so install-cert.sh has a worker_vm to
# PATCH). Re-fetch the recordings file path AFTER server start since the mock
# resets it on startup.
# ----------------------------------------------------------------------------
echo "==> pre-registering pexip-conf-1 with the mock"
curl --silent -u admin:test \
  -H "Content-Type: application/json" \
  -X POST \
  --data '{"name":"pexip-conf-1","hostname":"pexip-conf-1"}' \
  "${MOCK_URL}/api/admin/configuration/v1/worker_vm/" >/dev/null

# Clear the recordings file - we only want to assert on install-cert.sh's
# requests, not the test harness's setup calls.
: > "$RECORDINGS"

# ----------------------------------------------------------------------------
# install-cert.sh accepts PEXIP_API_ROOT as an override for testing - point
# it at the plain-HTTP mock and the script will exercise its real code path
# without needing TLS termination on the mock.
# ----------------------------------------------------------------------------
TEST_SCRIPT="${REPO_ROOT}/scripts/install-cert.sh"

# Generate two throwaway self-signed certs so the mock can extract distinct
# subject_name values for the Manager vs conf certs. Real Pexip parses CN
# from the PEM during certificates_import, and our mock mimics that, so the
# CNs must actually differ. We reuse the leaf as its own "issuer chain"
# (the mock doesn't validate chain integrity).
echo "==> generating throwaway test certs (manager + conf)"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "${WORK}/mgr.key" -out "${WORK}/mgr.crt" \
  -subj "/CN=pexip-mgr.test.example.com" 2>/dev/null
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "${WORK}/conf.key" -out "${WORK}/conf.crt" \
  -subj "/CN=pexip-conf-1.test.example.com" 2>/dev/null

MGR_LEAF_PEM="$(cat "${WORK}/mgr.crt")"
MGR_KEY_PEM="$(cat "${WORK}/mgr.key")"
MGR_ISSUER_PEM="$MGR_LEAF_PEM"

CONF_LEAF_PEM="$(cat "${WORK}/conf.crt")"
CONF_KEY_PEM="$(cat "${WORK}/conf.key")"
CONF_ISSUER_PEM="$CONF_LEAF_PEM"

# ----------------------------------------------------------------------------
# Run #1: fresh state, should POST cert + PATCH both nodes
# ----------------------------------------------------------------------------
# Disable set -e for the script call so we can inspect its exit code instead
# of aborting the whole test (which would also kill the mock and lose
# diagnostic info).
echo "==> run #1: fresh install"
set +e
PEXIP_API_ROOT="${MOCK_URL}" \
PEXIP_MANAGER_IP="ignored" \
PEXIP_ADMIN_PASSWORD="test" \
MANAGER_FQDN="pexip-mgr.test.example.com" \
MANAGER_CERT_PEM="$MGR_LEAF_PEM" \
MANAGER_ISSUER_PEM="$MGR_ISSUER_PEM" \
MANAGER_KEY_PEM="$MGR_KEY_PEM" \
CONF_FQDNS_CSV="pexip-conf-1.test.example.com" \
CONF_CERT_PEM="$CONF_LEAF_PEM" \
CONF_ISSUER_PEM="$CONF_ISSUER_PEM" \
CONF_KEY_PEM="$CONF_KEY_PEM" \
  "$TEST_SCRIPT" > "${WORK}/run1.stdout" 2> "${WORK}/run1.stderr"
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
  echo "FAIL: install-cert.sh exited $rc on run #1" >&2
  echo "--- stdout ---" >&2; cat "${WORK}/run1.stdout" >&2
  echo "--- stderr ---" >&2; cat "${WORK}/run1.stderr" >&2
  echo "--- recorded requests ---" >&2; cat "$RECORDINGS" >&2 2>/dev/null || true
  echo "--- mock stderr ---" >&2; cat "${WORK}/mock.stderr" >&2
  exit 1
fi

# ----------------------------------------------------------------------------
# Assertions on run #1
# ----------------------------------------------------------------------------
pass()  { printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
fail()  { printf "  \033[31mFAIL\033[0m  %s\n" "$*" >&2; echo "  Recordings:" >&2; cat "$RECORDINGS" >&2; exit 1; }

# Helper: count requests matching a method + path pattern
count_requests() {
  local method="$1" pattern="$2"
  jq -c --arg m "$method" --arg p "$pattern" \
    'select(.method == $m and (.path | test($p)))' "$RECORDINGS" | wc -l | tr -d ' '
}

# Helper: get the body of the Nth (1-indexed) matching request
body_of() {
  local method="$1" pattern="$2" n="$3"
  jq -rc --arg m "$method" --arg p "$pattern" \
    'select(.method == $m and (.path | test($p))) | .body' "$RECORDINGS" \
    | sed -n "${n}p"
}

echo
echo "==> assertions (run #1)"

# 1. Two POSTs to the certificates_import command endpoint (Manager + conf bundle)
n="$(count_requests POST '/api/admin/command/v1/platform/certificates_import/?$')"
[[ "$n" == "2" ]] || fail "expected 2 POSTs to /command/v1/platform/certificates_import/, got $n"
pass "two POSTs to /command/v1/platform/certificates_import/ (manager + conf bundles)"

# 2. Each bundle contains BOTH a certificate AND a private key in a single string
body="$(body_of POST '/api/admin/command/v1/platform/certificates_import/?$' 1)"
echo "$body" | jq -e '.bundle | contains("BEGIN CERTIFICATE")' >/dev/null \
  || fail "first certificates_import body is missing CERTIFICATE in bundle"
echo "$body" | jq -e '.bundle | contains("PRIVATE KEY")' >/dev/null \
  || fail "first certificates_import body is missing PRIVATE KEY in bundle"
pass "import bundle contains leaf + private key"

# 3. Manager assignment PATCH happened on /management_vm/1/ (note underscore!)
n="$(count_requests PATCH '/management_vm/1/$')"
[[ "$n" -ge "1" ]] || fail "expected PATCH /management_vm/1/, got $n"
pass "PATCH /management_vm/1/ to assign Manager cert"

# 4. The Manager PATCH body sets BOTH tls_certificate URI AND alternative_fqdn
body="$(body_of PATCH '/management_vm/1/$' 1)"
echo "$body" | jq -e '.tls_certificate | contains("/tls_certificate/")' >/dev/null \
  || fail "management_vm PATCH body missing tls_certificate URI: $body"
echo "$body" | jq -e '.alternative_fqdn | length > 0' >/dev/null \
  || fail "management_vm PATCH body missing alternative_fqdn: $body"
pass "management_vm PATCH sets tls_certificate URI + alternative_fqdn"

# 5. Conf node assignment PATCH happened on /worker_vm/1/ with tls_certificate URI
n="$(count_requests PATCH '/worker_vm/1/$')"
[[ "$n" -ge "1" ]] || fail "expected PATCH /worker_vm/1/, got $n"
pass "PATCH /worker_vm/1/ to assign conf-node cert"

body="$(body_of PATCH '/worker_vm/1/$' 1)"
echo "$body" | jq -e '.tls_certificate | contains("/tls_certificate/")' >/dev/null \
  || fail "worker_vm PATCH body missing tls_certificate URI: $body"
# worker_vm should NOT have alternative_fqdn (only management_vm has that field)
echo "$body" | jq -e 'has("alternative_fqdn") | not' >/dev/null \
  || fail "worker_vm PATCH body incorrectly includes alternative_fqdn: $body"
pass "worker_vm PATCH has tls_certificate URI but no alternative_fqdn"

# 6. Every request had basic auth
no_auth="$(jq -c 'select(.auth == null or .auth == "")' "$RECORDINGS" | wc -l | tr -d ' ')"
[[ "$no_auth" == "0" ]] || fail "$no_auth requests had no auth header"
pass "every request carried HTTP basic auth"

# ----------------------------------------------------------------------------
# Run #2: re-run against the same state - should PATCH existing certs, not
# POST new ones (idempotency check)
# ----------------------------------------------------------------------------
# Reset recordings, keep server state.
: > "$RECORDINGS"

echo
echo "==> run #2: re-run for idempotency"
set +e
PEXIP_API_ROOT="${MOCK_URL}" \
PEXIP_MANAGER_IP="ignored" \
PEXIP_ADMIN_PASSWORD="test" \
MANAGER_FQDN="pexip-mgr.test.example.com" \
MANAGER_CERT_PEM="$MGR_LEAF_PEM" \
MANAGER_ISSUER_PEM="$MGR_ISSUER_PEM" \
MANAGER_KEY_PEM="$MGR_KEY_PEM" \
CONF_FQDNS_CSV="pexip-conf-1.test.example.com" \
CONF_CERT_PEM="$CONF_LEAF_PEM" \
CONF_ISSUER_PEM="$CONF_ISSUER_PEM" \
CONF_KEY_PEM="$CONF_KEY_PEM" \
  "$TEST_SCRIPT" > "${WORK}/run2.stdout" 2> "${WORK}/run2.stderr"
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
  echo "FAIL: install-cert.sh exited $rc on run #2" >&2
  echo "--- stdout ---" >&2; cat "${WORK}/run2.stdout" >&2
  echo "--- stderr ---" >&2; cat "${WORK}/run2.stderr" >&2
  echo "--- recorded requests ---" >&2; cat "$RECORDINGS" >&2
  exit 1
fi

echo
echo "==> assertions (run #2 - idempotency)"

# On re-run with the same FQDNs, the certs already exist - install-cert.sh
# should NOT call certificates_import again, just re-assign.
new_imports="$(count_requests POST '/api/admin/command/v1/platform/certificates_import/?$')"
[[ "$new_imports" == "0" ]] || fail "re-run made $new_imports new imports (expected 0 - certs should be reused)"
pass "re-run did not re-import existing certs"

# But assignment PATCHes should still happen (the assignment is cheap and
# the script doesn't try to read the current value to skip).
n="$(count_requests PATCH '/management_vm/1/$')"
[[ "$n" -ge "1" ]] || fail "expected re-run to still PATCH /management_vm/1/, got $n"
pass "re-run re-PATCHed assignment (idempotent re-assign)"

echo
echo "All assertions passed."
exit 0
