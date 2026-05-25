#!/usr/bin/env bash
# ============================================================================
# test-destroy-prompt.sh - test scripts/destroy.sh license checks and prompts.
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

PORT=18447
MOCK_URL="https://127.0.0.1:${PORT}"

# ----------------------------------------------------------------------------
# Copy scripts and terraform directories to sandbox
# ----------------------------------------------------------------------------
mkdir -p "$WORK/scripts"
mkdir -p "$WORK/terraform"
mkdir -p "$WORK/bin"

cp "$REPO_ROOT/scripts/destroy.sh" "$WORK/scripts/"
cp "$REPO_ROOT/scripts/deactivate-license.py" "$WORK/scripts/"
cp "$REPO_ROOT/terraform/outputs.tf" "$WORK/terraform/"

# Create a mock terraform executable
cat << 'EOF' > "$WORK/bin/terraform"
#!/usr/bin/env bash
if [[ "$1" == "output" && "$2" == "-json" ]]; then
  echo '{"management_public_ip": {"value": "127.0.0.1:18447"}}'
elif [[ "$1" == "destroy" ]]; then
  echo "MOCK_TERRAFORM_DESTROY_SUCCESS"
  exit 0
else
  echo "mock-terraform: unknown command $1 $2" >&2
  exit 1
fi
EOF
chmod +x "$WORK/bin/terraform"

# Set up PATH to override terraform
export PATH="$WORK/bin:$PATH"

# Create dummy tfvars in the sandbox
echo 'pexip_admin_password = "test"' > "$WORK/terraform/terraform.tfvars"

# Generate certificates for HTTPS mock
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "${WORK}/mock.key" -out "${WORK}/mock.crt" \
  -subj "/CN=127.0.0.1" 2>/dev/null

STATE_FILE="${WORK}/state.json"
reset_state() {
  cat << 'EOF' > "$STATE_FILE"
{
  "licence": [
    {
      "id": 1,
      "entitlement_id": "TEST-LICENSE-1",
      "description": "Mock Active License 1",
      "resource_uri": "/api/admin/configuration/v1/licence/1/"
    }
  ],
  "_next_id": {
    "licence": 2
  }
}
EOF
}
reset_state

# Start mock server
python3 "${SCRIPT_DIR}/mock-pexip.py" \
  --port "$PORT" \
  --recordings-dir "$WORK" \
  --state-file "$STATE_FILE" \
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

# Helpers
pass()  { printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
fail()  { printf "  \033[31mFAIL\033[0m  %s\n" "$*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Case 1: Active licenses present, user declines return (should abort)
# ----------------------------------------------------------------------------
echo "==> Case 1: User declines returning active licenses"
reset_state

# We simulate:
# 1. "n" for "Would you like to automatically return these licenses to Pexip now? (y/n)"
set +e
output=$(echo -e "n" | bash "$WORK/scripts/destroy.sh" 2>&1)
destroy_exit=$?
set -e

if [[ $destroy_exit -eq 0 ]]; then
  fail "Expected destroy.sh to fail when user declines returning licenses, but it exited 0."
fi

if [[ ! "$output" =~ "Aborted. License must be returned before destroying the node." ]]; then
  fail "Expected abort message in output, got: $output"
fi
pass "Successfully aborted when user declined license return"

# ----------------------------------------------------------------------------
# Case 2: Active licenses present, user accepts return, then confirms destroy
# ----------------------------------------------------------------------------
echo "==> Case 2: User accepts returning licenses and confirms destroy"
reset_state

# We simulate:
# 1. "y" for "Would you like to automatically return these licenses to Pexip now? (y/n)"
# 2. "destroy" for "Type 'destroy' to confirm"
set +e
output=$(echo -e "y\ndestroy" | bash "$WORK/scripts/destroy.sh" 2>&1)
destroy_exit=$?
set -e

if [[ $destroy_exit -ne 0 ]]; then
  fail "Expected destroy.sh to exit 0 on successful license return and destroy confirmation, got $destroy_exit. Output: $output"
fi

if [[ ! "$output" =~ "Licenses returned successfully" ]]; then
  fail "Expected 'Licenses returned successfully' in output, got: $output"
fi

if [[ ! "$output" =~ "MOCK_TERRAFORM_DESTROY_SUCCESS" ]]; then
  fail "Expected terraform destroy to run and output success, got: $output"
fi
pass "Successfully returned licenses and destroyed stack"

# ----------------------------------------------------------------------------
# Case 3: No licenses present, user confirms destroy
# ----------------------------------------------------------------------------
echo "==> Case 3: No licenses present initially"
# Clear licenses in mock state by overwriting state file and restarting server (or just letting the state persist from Case 2 since Case 2 deleted them)
# Wait, Case 2 already deleted the licenses in mock memory, so state should be clear.
# Let's verify by just running check and then confirming destroy.
# We simulate:
# 1. "destroy" for "Type 'destroy' to confirm"
set +e
output=$(echo -e "destroy" | bash "$WORK/scripts/destroy.sh" 2>&1)
destroy_exit=$?
set -e

if [[ $destroy_exit -ne 0 ]]; then
  fail "Expected destroy.sh to exit 0 when no licenses present, got $destroy_exit. Output: $output"
fi

if [[ "$output" =~ "WARNING: ACTIVE LICENSES DETECTED" ]]; then
  fail "Unexpected license detection warning in output: $output"
fi

if [[ ! "$output" =~ "MOCK_TERRAFORM_DESTROY_SUCCESS" ]]; then
  fail "Expected terraform destroy to run, got: $output"
fi
pass "Successfully bypassed license return and destroyed stack when no licenses present"

echo "All destroy.sh prompt integration tests passed successfully."
exit 0
