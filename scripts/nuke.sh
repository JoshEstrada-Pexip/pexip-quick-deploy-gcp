#!/usr/bin/env bash
# ============================================================================
# nuke.sh — wipe every Pexip Quick Deploy resource via gcloud
#
# Use this when:
#   - terraform.tfstate is missing or partial (e.g. fresh Cloud Shell clone
#     after a previous session left orphans in your project)
#   - destroy.sh can't run because state is corrupted
#   - you just want a clean slate before re-running setup.sh
#
# Idempotent: every delete uses --quiet and ignores "not found", so running
# this on a clean project is a no-op. Safe to paste into the terminal even
# if you're not sure what's there.
#
# What it deletes (everything matching the names this repo creates):
#   - Compute Engine VMs: pexip-mgr, pexip-conf-*
#   - Reserved IPs:        pexip-mgr-{public,private}, pexip-conf-*-{public,private}
#   - Firewall rules:      pexip-quick-net-{admin-access,conf-web,conf-signaling,internal}
#   - Subnet + Network:    pexip-quick-net-<region>, pexip-quick-net
#   - Copied images:       pexip-quick-pexip-infinity-*
#   - Service account:     pexip-quick-sa
#
# Does NOT delete: your GCP project, billing setup, IAM grants, or anything
# else outside this repo's naming convention.
# ============================================================================
set -uo pipefail

# Resolve the project ID. Priority: $1 arg > tfvars > gcloud config > env.
PROJ="${1:-}"
TFVARS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/terraform/terraform.tfvars"
if [[ -z "$PROJ" && -f "$TFVARS" ]]; then
  PROJ="$(grep -E '^project_id' "$TFVARS" | head -1 | cut -d'"' -f2 || true)"
fi
[[ -z "$PROJ" ]] && PROJ="$(gcloud config get-value project 2>/dev/null || true)"
[[ -z "$PROJ" ]] && PROJ="${GOOGLE_CLOUD_PROJECT:-${DEVSHELL_PROJECT_ID:-}}"
if [[ -z "$PROJ" ]]; then
  echo "ERROR: no project ID. Pass it as the first arg:" >&2
  echo "  $0 my-project-id" >&2
  exit 1
fi

# Region is harder to recover; try tfvars then default to us-west1.
REGION=""
[[ -f "$TFVARS" ]] && REGION="$(grep -E '^region' "$TFVARS" | head -1 | cut -d'"' -f2 || true)"
REGION="${REGION:-us-west1}"
ZONE_LETTER=""
[[ -f "$TFVARS" ]] && ZONE_LETTER="$(grep -E '^zone_letter' "$TFVARS" | head -1 | cut -d'"' -f2 || true)"
ZONE="${REGION}-${ZONE_LETTER:-b}"

echo "Wiping Pexip Quick Deploy resources from:"
echo "  project: $PROJ"
echo "  region:  $REGION"
echo "  zone:    $ZONE"
echo

# Silence gcloud's confirmation prompts; we already confirmed with the user
# by virtue of them running this script.
GFLAGS=(--project="$PROJ" --quiet)

# Ensure Python requests library is installed for the license check
if ! python3 -c "import requests" 2>/dev/null; then
  echo "Installing Python 'requests' package for license check..."
  python3 -m pip install --user -q requests || true
fi

# Run pre-nuke license check
if python3 -c "import requests" 2>/dev/null; then
  echo "Checking for active Pexip licenses..."
  # Run the check helper script.
  # We disable set -e temporarily to capture exit code 10 or other non-zero codes.
  set +e
  python3 "$(dirname "${BASH_SOURCE[0]}")/deactivate-license.py" --check
  check_status=$?
  set -e

  if [[ $check_status -eq 10 ]]; then
    echo -e "\033[93m"
    echo "=============================================================="
    echo "WARNING: ACTIVE LICENSES DETECTED"
    echo "=============================================================="
    echo "Active Pexip platform license(s) were found on the Management Node."
    echo "If you delete this VM without deactivating/returning the license,"
    echo "it may become permanently locked or lost!"
    echo "=============================================================="
    echo -e "\033[0m"

    read -r -p "Would you like to automatically return these licenses to Pexip now? (y/n): " return_confirm
    if [[ "$return_confirm" =~ ^[Yy]$ ]]; then
      echo "Initiating license return..."
      set +e
      python3 "$(dirname "${BASH_SOURCE[0]}")/deactivate-license.py" --deactivate
      deactivate_status=$?
      set -e
      if [[ $deactivate_status -ne 0 ]]; then
        echo -e "\033[91m[ERROR] License deactivation failed. Aborting nuke to prevent license loss.\033[0m"
        exit 1
      fi
      echo -e "\033[92m[SUCCESS] Licenses returned successfully.\033[0m"
    else
      echo "Aborted. License must be returned before deleting the node."
      exit 1
    fi
  elif [[ $check_status -ne 0 ]]; then
    echo -e "\033[91m[WARNING] License check failed with exit code $check_status.\033[0m"
    read -r -p "Do you want to proceed with nuke anyway? (y/n): " proceed_anyway
    if [[ ! "$proceed_anyway" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      exit 1
    fi
  fi
else
  echo -e "\033[93m[WARNING] Python 'requests' module not available. Skipping pre-nuke license check.\033[0m"
fi

# Clean up Cloudflare DNS records if TFVARS exists with authentication
if [[ -f "$TFVARS" ]] && grep -q "cloudflare_api_token" "$TFVARS"; then
  echo "==> Cleaning up Cloudflare DNS records (A, SRV, TXT)..."
  python3 "$(dirname "${BASH_SOURCE[0]}")/clean-cloudflare-srv.py" || true
  echo
fi

# Discover names dynamically so we catch any count > 1 (e.g. 3 conf nodes,
# multi-zone deploys, etc) without hardcoding indices.
echo "==> Discovering pexip-quick-* resources..."
INSTANCES="$(gcloud compute instances list --filter='name~^pexip-' --format='value(name,zone)' "${GFLAGS[@]}" 2>/dev/null || true)"
ADDRESSES="$(gcloud compute addresses list --filter='name~^pexip-' --format='value(name,region)' "${GFLAGS[@]}" 2>/dev/null || true)"
FIREWALLS="$(gcloud compute firewall-rules list --filter='name~^pexip-quick-net-' --format='value(name)' "${GFLAGS[@]}" 2>/dev/null || true)"
SUBNETS="$(gcloud compute networks subnets list --filter='name~^pexip-quick-net-' --format='value(name,region)' "${GFLAGS[@]}" 2>/dev/null || true)"
NETWORKS="$(gcloud compute networks list --filter='name~^pexip-quick-net' --format='value(name)' "${GFLAGS[@]}" 2>/dev/null || true)"
IMAGES="$(gcloud compute images list --filter='name~^pexip-quick-' --format='value(name)' "${GFLAGS[@]}" --no-standard-images 2>/dev/null || true)"
SAS="$(gcloud iam service-accounts list --filter='email~^pexip-quick-sa@' --format='value(email)' "${GFLAGS[@]}" 2>/dev/null || true)"

# Helper that runs a gcloud delete in the background and only complains if
# it fails for a reason other than "not found".
del() {
  local label="$1"; shift
  echo "  - $label"
  "$@" 2>&1 | grep -v -E "was not found|already being used|^Deleted " || true
}

# ----------------------------------------------------------------------------
# Order matters: VMs -> addresses -> firewalls -> subnets -> network -> rest.
# A network can't be deleted while it has dependents.
# ----------------------------------------------------------------------------

echo "==> Deleting VMs..."
if [[ -n "$INSTANCES" ]]; then
  while IFS=$'\t' read -r name zone_url; do
    [[ -z "$name" ]] && continue
    # zone_url is a full URL; take the last segment.
    z="${zone_url##*/}"
    del "instance $name ($z)" \
      gcloud compute instances delete "$name" --zone="$z" "${GFLAGS[@]}"
  done <<<"$INSTANCES"
fi

echo "==> Deleting reserved IP addresses..."
if [[ -n "$ADDRESSES" ]]; then
  while IFS=$'\t' read -r name region_url; do
    [[ -z "$name" ]] && continue
    r="${region_url##*/}"
    del "address $name ($r)" \
      gcloud compute addresses delete "$name" --region="$r" "${GFLAGS[@]}"
  done <<<"$ADDRESSES"
fi

echo "==> Deleting firewall rules..."
if [[ -n "$FIREWALLS" ]]; then
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    del "firewall $name" \
      gcloud compute firewall-rules delete "$name" "${GFLAGS[@]}"
  done <<<"$FIREWALLS"
fi

echo "==> Deleting subnets..."
if [[ -n "$SUBNETS" ]]; then
  while IFS=$'\t' read -r name region_url; do
    [[ -z "$name" ]] && continue
    r="${region_url##*/}"
    del "subnet $name ($r)" \
      gcloud compute networks subnets delete "$name" --region="$r" "${GFLAGS[@]}"
  done <<<"$SUBNETS"
fi

echo "==> Deleting VPC networks..."
if [[ -n "$NETWORKS" ]]; then
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    del "network $name" \
      gcloud compute networks delete "$name" "${GFLAGS[@]}"
  done <<<"$NETWORKS"
fi

echo "==> Deleting copied images..."
if [[ -n "$IMAGES" ]]; then
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    del "image $name" \
      gcloud compute images delete "$name" "${GFLAGS[@]}"
  done <<<"$IMAGES"
fi

echo "==> Deleting service accounts..."
if [[ -n "$SAS" ]]; then
  while IFS= read -r email; do
    [[ -z "$email" ]] && continue
    del "service account $email" \
      gcloud iam service-accounts delete "$email" "${GFLAGS[@]}"
  done <<<"$SAS"
fi

# Wipe local state so the next `terraform apply` starts from a clean slate.
TFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/terraform"
if [[ -d "$TFDIR" ]]; then
  echo "==> Wiping local terraform state ($TFDIR/terraform.tfstate*, conf-configs.json)..."
  rm -f "$TFDIR"/terraform.tfstate "$TFDIR"/terraform.tfstate.backup "$TFDIR"/conf-configs.json
fi

echo
echo "Done. Project should now be clean. Run scripts/setup.sh to deploy fresh."
