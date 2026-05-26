#!/usr/bin/env bash
# ============================================================================
# Pexip Quick Deploy - AI Safety Hook for Google Antigravity
#
# Intercepts run_command tool calls to prevent accidental resource
# destruction when a license is configured or active.
# ============================================================================

# Read the tool call context from stdin
INPUT_JSON=$(cat)

# Extract tool name and command
TOOL_NAME=$(echo "$INPUT_JSON" | jq -r '.tool_name // empty' 2>/dev/null)
COMMAND=$(echo "$INPUT_JSON" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [[ -z "$COMMAND" ]]; then
  # If we cannot parse a command, allow the tool call
  echo '{"decision": "continue"}'
  exit 0
fi

# Detect destructive actions
IS_DESTRUCTIVE=false
if echo "$COMMAND" | grep -Ei -q 'delete|destroy|nuke|disable'; then
  if echo "$COMMAND" | grep -Ei -q 'gcloud|terraform|nuke.sh|destroy.sh'; then
    IS_DESTRUCTIVE=true
  fi
fi

if [[ "$IS_DESTRUCTIVE" == "true" ]]; then
  # Find repo root
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  CONFIG_FILE="${CONFIG_FILE:-${REPO_ROOT}/pexip-config.yaml}"
  TFVARS_FILE="${TFVARS_FILE:-${REPO_ROOT}/terraform/terraform.tfvars}"

  LICENSE_ACTIVE=false
  LICENSE_KEY=""

  # Check if a license key is configured in pexip-config.yaml
  if [[ -f "$CONFIG_FILE" ]]; then
    # Extract license_key using grep/awk/tr
    LICENSE_KEY=$(grep -E '^\s*license_key\s*:' "$CONFIG_FILE" | awk -F: '{print $2}' | tr -d ' "' | tr -d "'" || true)
  fi

  # Check if a license key is configured in terraform.tfvars
  if [[ -z "$LICENSE_KEY" && -f "$TFVARS_FILE" ]]; then
    LICENSE_KEY=$(grep -E 'license_key' "$TFVARS_FILE" || true)
  fi

  # If we have a license key configured, flag it
  if [[ -n "$LICENSE_KEY" && "$LICENSE_KEY" != "\"\"" && "$LICENSE_KEY" != "''" ]]; then
    LICENSE_ACTIVE=true
  fi

  # Check if there is an active GCE deployment
  PROJ_ID=""
  # Extract project ID from arguments
  PROJ_ID=$(echo "$COMMAND" | grep -oE '\-\-project[ =][^ ]+' | sed -E 's/\-\-project[ =]//' || true)

  if [[ -z "$PROJ_ID" && -f "$TFVARS_FILE" ]]; then
    PROJ_ID=$(grep -E '^\s*project_id\s*=' "$TFVARS_FILE" | sed -E 's/^\s*project_id\s*=\s*["'\'']?([^"'\''\s]*)["'\'']?/\1/' || true)
  fi

  if [[ -z "$PROJ_ID" ]]; then
    PROJ_ID=$(gcloud config get-value project 2>/dev/null || true)
  fi

  ACTIVE_DEPLOYMENT=false
  if [[ -n "$PROJ_ID" ]]; then
    # Check if VMs starting with pexip- exist
    VM_COUNT=$(gcloud compute instances list --project="$PROJ_ID" --filter="name~^pexip-" --format="value(name)" 2>/dev/null | grep -c . || true)
    if [[ $VM_COUNT -gt 0 ]]; then
      ACTIVE_DEPLOYMENT=true
    fi
  fi

  # If there is an active deployment or a configured license, block the tool call
  if [[ "$ACTIVE_DEPLOYMENT" == "true" || "$LICENSE_ACTIVE" == "true" ]]; then
    # Output the deny decision to stdout and exit with code 2 (Deny/Block)
    jq -n --arg cmd "$COMMAND" --arg proj "$PROJ_ID" --arg active "$ACTIVE_DEPLOYMENT" --arg lic "$LICENSE_ACTIVE" '{
      decision: "deny",
      reason: "Destructive command blocked by local safety hook.\nCommand: \($cmd)\nActive Deployment: \($active)\nLicense Configured: \($lic)\nGCP Project: \($proj)\nTo run this, you must deactivate/release your license first, or run the command manually."
    }'
    exit 2
  fi
fi

# Otherwise, allow the tool call (exit 0)
echo '{"decision": "continue"}'
exit 0
