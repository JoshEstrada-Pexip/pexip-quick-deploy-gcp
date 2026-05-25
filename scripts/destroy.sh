#!/usr/bin/env bash
# Tear down the Pexip Quick Deploy stack.
#
# After the refactor that dropped the Pexip terraform provider, terraform
# state only holds GCP resources, so destroy is just `terraform destroy`.
# We still wrap in a retry loop because Cloud Shell -> compute.googleapis.com
# occasionally has TCP-refused blips that can interrupt a multi-minute apply.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}/terraform"

if [[ ! -f terraform.tfvars ]]; then
  echo "No terraform.tfvars found - nothing to destroy."
  exit 0
fi

# Ensure Python requests library is installed for the license check
if ! python3 -c "import requests" 2>/dev/null; then
  echo "Installing Python 'requests' package for license check..."
  python3 -m pip install --user -q requests || true
fi

# Run pre-destroy license check
if python3 -c "import requests" 2>/dev/null; then
  echo "Checking for active Pexip licenses..."
  # Run the check helper script.
  # We disable set -e temporarily to capture exit code 10 or other non-zero codes.
  set +e
  python3 ../scripts/deactivate-license.py --check
  check_status=$?
  set -e

  if [[ $check_status -eq 10 ]]; then
    echo -e "\033[93m"
    echo "=============================================================="
    echo "WARNING: ACTIVE LICENSES DETECTED"
    echo "=============================================================="
    echo "Active Pexip platform license(s) were found on the Management Node."
    echo "If you destroy this VM without deactivating/returning the license,"
    echo "it may become permanently locked or lost!"
    echo "=============================================================="
    echo -e "\033[0m"

    read -r -p "Would you like to automatically return these licenses to Pexip now? (y/n): " return_confirm
    if [[ "$return_confirm" =~ ^[Yy]$ ]]; then
      echo "Initiating license return..."
      set +e
      python3 ../scripts/deactivate-license.py --deactivate
      deactivate_status=$?
      set -e
      if [[ $deactivate_status -ne 0 ]]; then
        echo -e "\033[91m[ERROR] License deactivation failed. Aborting destroy to prevent license loss.\033[0m"
        exit 1
      fi
      echo -e "\033[92m[SUCCESS] Licenses returned successfully.\033[0m"

      echo "Verifying active license status..."
      set +e
      python3 ../scripts/deactivate-license.py --check
      recheck_status=$?
      set -e
      if [[ $recheck_status -eq 10 ]]; then
        echo -e "\033[91m[ERROR] Active license(s) still detected on the Management Node after deactivation! Aborting destroy.\033[0m"
        exit 1
      elif [[ $recheck_status -ne 0 ]]; then
        echo -e "\033[91m[ERROR] License status doublecheck failed with exit code $recheck_status. Aborting destroy.\033[0m"
        exit 1
      fi
      echo -e "\033[92m[SUCCESS] Confirmed: 0 active licenses remain. Ready to proceed.\033[0m"
    else
      echo "Aborted. License must be returned before destroying the node."
      exit 1
    fi
  elif [[ $check_status -ne 0 ]]; then
    echo -e "\033[91m[ERROR] License check failed with exit code $check_status.\033[0m"
    read -r -p "Do you want to proceed with destroy anyway? (y/n): " proceed_anyway
    if [[ ! "$proceed_anyway" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      exit 1
    fi
  fi
else
  echo -e "\033[93m[WARNING] Python 'requests' module not available. Skipping pre-destroy license check.\033[0m"
fi

echo "This will permanently delete the Pexip VMs, network, images, and service account."
read -r -p "Type 'destroy' to confirm: " confirm
[[ "$confirm" == "destroy" ]] || { echo "Aborted."; exit 1; }

cleanup_dns() {
  if [[ -f terraform.tfvars ]] && grep -q "cloudflare_api_token" terraform.tfvars; then
    echo
    echo "==> Cleaning up any leftover Cloudflare DNS records..."
    python3 ../scripts/clean-cloudflare-srv.py || true
  fi
}

# Cloud Shell -> GCP API blips: retry up to 3 times with a backoff.
max_attempts=3
for attempt in $(seq 1 $max_attempts); do
  echo
  echo "==> terraform destroy (attempt $attempt of $max_attempts)..."
  if terraform destroy -auto-approve -parallelism=4; then
    echo "Destroy complete."
    # Clean up the file the refactor's helper script wrote so a re-run
    # doesn't try to read a stale config from a destroyed Manager.
    rm -f conf-configs.json
    cleanup_dns
    exit 0
  fi
  if [[ $attempt -lt $max_attempts ]]; then
    echo "Destroy failed; waiting 20s before retry..."
    sleep 20
  fi
done

echo
  echo "==> Refresh keeps failing. Retrying without state refresh..."
  echo "    (Terraform will delete what's in state without checking GCP first.)"
if terraform destroy -auto-approve -parallelism=4 -refresh=false; then
  echo "Destroy complete (without refresh)."
  rm -f conf-configs.json
  cleanup_dns
  exit 0
fi

cat <<'EOF'

Destroy still failing. This usually means Cloud Shell has a persistent
network issue this session. Try:

  1. Restart Cloud Shell (three-dot menu -> Restart), then re-run.
  2. Or delete resources manually via the GCP console - look in:
     Compute Engine > VM instances, Images, Addresses
     VPC network > Firewall rules, Networks
     IAM & admin > Service accounts
EOF
exit 1
