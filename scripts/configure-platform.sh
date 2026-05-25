#!/usr/bin/env bash
# ============================================================================
# Pexip Infinity - Stage 2 Configuration Sync Wrapper
# ============================================================================

set -o errexit
set -o pipefail

# Determine repository root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT"

# Source modern UI helper library
if [[ -f "scripts/ui.sh" ]]; then
  source "scripts/ui.sh"
else
  # Fallback basic loggers if ui.sh is not present
  print_step() { echo -e "\n=== $2 ==="; }
  print_success() { echo -e "[SUCCESS] $*"; }
  print_error() { echo -e "[ERROR] $*" >&2; }
  print_info() { echo -e "[INFO] $*"; }
fi

print_step "S2" "Pexip Stage 2 Declarative Configuration"

# 1. Check for configuration file
if [[ ! -f "pexip-config.yaml" ]]; then
  print_info "Configuration file 'pexip-config.yaml' not found in workspace root."
  if [[ -f "pexip-config.example.yaml" ]]; then
    print_info "Creating 'pexip-config.yaml' from the template..."
    cp pexip-config.example.yaml pexip-config.yaml
    print_success "Created 'pexip-config.yaml'."
    print_info "Please edit 'pexip-config.yaml' with your settings and re-run this script."
    exit 0
  else
    print_error "Template file 'pexip-config.example.yaml' is also missing. Cannot bootstrap configuration."
    exit 1
  fi
fi

# 2. Verify Terraform State and Variables
TFVARS="terraform/terraform.tfvars"
if [[ ! -f "$TFVARS" ]]; then
  print_error "Terraform variables file not found at $TFVARS."
  print_info "Please run './scripts/setup.sh' to deploy the GCP infrastructure first."
  exit 1
fi

# Extract admin password from tfvars
print_info "Extracting credentials from $TFVARS..."
ADMIN_PASSWORD=$(grep -E '^\s*pexip_admin_password\s*=' "$TFVARS" | cut -d'=' -f2- | tr -d ' "' | tr -d "'")
if [[ -z "$ADMIN_PASSWORD" ]]; then
  print_error "Could not find 'pexip_admin_password' in $TFVARS."
  exit 1
fi

# 3. Retrieve Management Node Host/IP
print_info "Retrieving Pexip Management Node host from Terraform..."
if ! command -v terraform &>/dev/null; then
  print_error "Terraform CLI is not installed or not in PATH."
  exit 1
fi

MGR_URL=$(terraform -chdir=terraform output -raw management_admin_url 2>/dev/null || true)
if [[ -z "$MGR_URL" || "$MGR_URL" == *"No outputs"* || "$MGR_URL" == *"Error"* ]]; then
  print_error "Could not retrieve 'management_admin_url' from Terraform outputs."
  print_info "Make sure your Terraform deployment completed successfully."
  exit 1
fi

# Extract host (FQDN or IP) from URL
MGR_HOST=$(echo "$MGR_URL" | sed -e 's|^[^/]*//||' -e 's|/.*$||' -e 's|:.*$||')
print_success "Found Management Node Host: $MGR_HOST"

# 4. Check and install Python dependencies
print_info "Checking Python dependencies..."
if ! python3 -c "import yaml, requests" 2>/dev/null; then
  print_info "Installing missing dependencies ('requests' and 'PyYAML') inside user space..."
  python3 -m pip install --user -q requests PyYAML
  print_success "Dependencies installed."
fi

# 5. Execute Configuration Sync
print_info "Starting declarative configuration sync..."
export PYTHONWARNINGS="ignore:Unverified HTTPS request"

if python3 scripts/sync-config.py --host "$MGR_HOST" --password "$ADMIN_PASSWORD" --config "pexip-config.yaml"; then
  echo
  print_success "Stage 2 Configuration Synchronization Succeeded!"
else
  echo
  print_error "Configuration synchronization failed. Check logs above."
  exit 1
fi
