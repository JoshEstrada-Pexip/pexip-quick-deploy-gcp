#!/usr/bin/env bash
# ============================================================================
# test-safety-hook.sh - Automated mock tests for Google Antigravity safety hook
# ============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK_SCRIPT="${REPO_ROOT}/.agents/hooks/gcloud-safety-hook.sh"

# Colors for test output
GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

# Create a clean mock directory for temp config files
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export CONFIG_FILE="${TEST_DIR}/pexip-config.yaml"
export TFVARS_FILE="${TEST_DIR}/terraform/terraform.tfvars"
mkdir -p "${TEST_DIR}/terraform"

# Set up mock gcloud behavior control variables
export MOCK_VM_COUNT=0
export MOCK_PROJECT="mock-safety-project"

# Mock gcloud command via function export
gcloud() {
  if [[ "$*" == *"config get-value project"* ]]; then
    echo "$MOCK_PROJECT"
  elif [[ "$*" == *"compute instances list"* ]]; then
    for ((i=0; i<MOCK_VM_COUNT; i++)); do
      echo "pexip-node-$i"
    done
  fi
}
export -f gcloud

failed=0

run_test() {
  local test_name="$1"
  local tool_input_command="$2"
  local expect_deny="$3"

  # Format tool call context JSON input
  local input_json
  input_json=$(jq -n --arg cmd "$tool_input_command" '{
    tool_name: "run_command",
    tool_input: {
      command: $cmd
    }
  }')

  # Execute hook script and capture exit code
  local output
  local rc=0
  output=$(echo "$input_json" | "$HOOK_SCRIPT" 2>/dev/null) || rc=$?

  local is_denied=false
  if [[ $rc -eq 2 ]] && [[ -n "$output" ]] && echo "$output" | jq -e '.decision == "deny"' >/dev/null 2>&1; then
    is_denied=true
  fi

  if [[ "$expect_deny" == "true" ]]; then
    if [[ "$is_denied" == "true" ]]; then
      echo -e "  [${GREEN}PASS${RESET}] $test_name (correctly blocked with exit code 2)"
    else
      echo -e "  [${RED}FAIL${RESET}] $test_name (expected command to be blocked, but it was allowed. exit code: $rc, output: $output)"
      failed=$((failed + 1))
    fi
  else
    if [[ "$is_denied" == "false" ]]; then
      echo -e "  [${GREEN}PASS${RESET}] $test_name (correctly allowed with exit code $rc)"
    else
      echo -e "  [${RED}FAIL${RESET}] $test_name (expected command to be allowed, but it was blocked. exit code: $rc, output: $output)"
      failed=$((failed + 1))
    fi
  fi
}

echo -e "\nRunning Google Antigravity Safety Hook Mock Tests..."
echo "=========================================================="

# Test Case 1: Safe command should always be allowed
echo 'license_key: ""' > "$CONFIG_FILE"
echo 'project_id = "mock-safety-project"' > "$TFVARS_FILE"
MOCK_VM_COUNT=0
run_test "Safe command (gcloud instances list)" "gcloud compute instances list --project=mock-safety-project" "false"

# Test Case 2: Destructive command when project is empty and no license key exists
MOCK_VM_COUNT=0
run_test "Destructive command with empty project" "gcloud compute instances delete pexip-mgr --project=mock-safety-project" "false"

# Test Case 3: Destructive command when GCE VMs DO exist in the project
MOCK_VM_COUNT=2
run_test "Destructive command with active VMs in project" "gcloud compute instances delete pexip-mgr --project=mock-safety-project" "true"

# Test Case 4: Destructive command when a license key is configured in pexip-config.yaml
MOCK_VM_COUNT=0
echo 'license_key: "12345-abcde-67890"' > "$CONFIG_FILE"
run_test "Destructive command with license key configured in config" "gcloud compute instances delete pexip-mgr --project=mock-safety-project" "true"

# Test Case 5: Destructive command (terraform destroy) when a license key is configured
run_test "Terraform destroy with license key configured" "terraform destroy -auto-approve" "true"

# Test Case 6: Safe command even when license is configured (should not block normal read/list ops)
run_test "Safe command with license key configured" "gcloud compute instances describe pexip-mgr --project=mock-safety-project" "false"

echo "=========================================================="
if [[ $failed -eq 0 ]]; then
  echo -e "${GREEN}All tests passed successfully!${RESET}\n"
  exit 0
else
  echo -e "${RED}$failed test(s) failed.${RESET}\n"
  exit 1
fi
