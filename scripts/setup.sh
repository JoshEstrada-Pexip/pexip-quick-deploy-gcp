#!/usr/bin/env bash
# ============================================================================
# Pexip Quick Deploy - interactive setup
#
# Prompts for inputs, auto-detects latest published Pexip images, writes
# terraform/terraform.tfvars, enables required GCP APIs, then runs
# `terraform apply`. After this finishes, the Management Node and
# Conferencing Nodes are fully bootstrapped - no SSH needed.
# ============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"
TFVARS="${TF_DIR}/terraform.tfvars"
PEXIP_IMG_PROJECT="pexip-product-images"

# Known-good Pexip Infinity image names. Used as fallback defaults when the
# live lookup against pexip-product-images returns nothing (Pexip grants
# read access to individual images but does NOT allow listing the project,
# so `gcloud compute images list` is empty for external users). Bump these
# when Pexip publishes a new release; the user can still override at the
# prompt.
PEXIP_DEFAULT_MGMT_IMAGE="pexip-infinity-mgmt-node-40-0-0-83304-0-0"
PEXIP_DEFAULT_CONF_IMAGE="pexip-infinity-conf-node-40-0-0-83304-0-0"

# Source the modern UI helpers
source "${REPO_ROOT}/scripts/ui.sh"

# Run a command with a live spinner + elapsed counter. Captures stdout and
# stderr to temp files (so we don't swallow auth prompts behind /dev/null
# like the previous version did). After the command finishes, stdout is
# echoed to this function's stdout so it can be captured with $(...).
# Stderr replays only on failure.
#
# Usage:
#   result="$(with_spinner "label" cmd args...)"   # capture stdout
#   with_spinner "label" cmd args...                # just run with feedback
spin() {
  local label="$1"; shift
  local frames='|/-\' out_file err_file
  out_file="$(mktemp)"; err_file="$(mktemp)"
  ( "$@" >"$out_file" 2>"$err_file" ) &
  local pid=$! i=0 start=$SECONDS
  if [[ -t 2 ]]; then
    while kill -0 "$pid" 2>/dev/null; do
      local frame=${frames:i++%${#frames}:1}
      printf "\r  %s %s (%ss)" "$frame" "$label" "$((SECONDS-start))" >&2
      sleep 0.2
    done
  fi
  wait "$pid"
  local rc=$?
  [[ -t 2 ]] && printf "\r\033[K" >&2
  if [[ $rc -eq 0 ]]; then
    echo -e "  ${TEXT_GREEN}✔${RESET}  ${TEXT_BOLD}${label}${RESET} ... done (${TEXT_MUTED}$((SECONDS-start))s${RESET})" >&2
  else
    echo -e "  ${TEXT_RED}✖${RESET}  ${TEXT_BOLD}${label}${RESET} ... FAILED (${TEXT_MUTED}$((SECONDS-start))s${RESET})" >&2
    [[ -s "$err_file" ]] && sed 's/^/    /' "$err_file" >&2
  fi
  cat "$out_file"
  rm -f "$out_file" "$err_file"
  return $rc
}

# Helper function to check for existing/orphaned GCP resources
check_orphans() {
  local proj="$1"
  local inst_n net_n sa_n img_n addr_n fw_n

  # A local wrapper to count lines returned by a gcloud list command
  count_res() {
    gcloud "$@" --project="$proj" --format='value(name)' 2>/dev/null | grep -c . || true
  }

  inst_n=$(count_res compute instances list --filter='name~^pexip-')
  net_n=$(count_res compute networks list --filter='name~^pexip-quick-net')
  sa_n=$(gcloud iam service-accounts list --project="$proj" --filter='email~^pexip-quick-sa@' --format='value(email)' 2>/dev/null | grep -c . || true)
  img_n=$(count_res compute images list --filter='name~^pexip-quick-' --no-standard-images)
  addr_n=$(count_res compute addresses list --filter='name~^pexip-')
  fw_n=$(count_res compute firewall-rules list --filter='name~^pexip-quick-net-')

  echo "$inst_n $net_n $sa_n $img_n $addr_n $fw_n"
}

echo
echo -e "  ${TEXT_BOLD}${TEXT_PURPLE}pexip quick-deploy${RESET}"
print_divider

for cmd in terraform gcloud curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    print_error "ERROR: '$cmd' is not on PATH."
    exit 1
  fi
done

# ----------------------------------------------------------------------------
# Project + region
# ----------------------------------------------------------------------------
project_id=""
if [[ $# -gt 0 ]]; then
  project_id="$1"
  shift
fi

step_num=1
print_next_step() {
  local title="$1"
  print_step "$step_num" "$title"
  ((step_num++))
}

print_next_step "Configure GCP Settings"

if [[ -z "$project_id" ]]; then
  # Cloud Shell exposes the active project via $GOOGLE_CLOUD_PROJECT and
  # $DEVSHELL_PROJECT_ID even when `gcloud config` has nothing set, so prefer
  # those before prompting blank.
  default_project="$(gcloud config get-value project 2>/dev/null || true)"
  [[ -z "$default_project" ]] && default_project="${GOOGLE_CLOUD_PROJECT:-}"
  [[ -z "$default_project" ]] && default_project="${DEVSHELL_PROJECT_ID:-}"
  project_id="$(ask_input 'GCP Project ID' "$default_project")"
fi

[[ -z "$project_id" ]] && { print_error "project_id is required"; exit 1; }
spin "Configuring active GCP project" gcloud config set project "$project_id" >/dev/null

# ----------------------------------------------------------------------------
# Select Deployment Mode
# ----------------------------------------------------------------------------
echo
setup_options=(
  "Simple (defaults, self-signed cert, no inputs)"
  "Simple - Licensed/TLS (defaults + DNS + License key)"
  "Advanced (customize region, sizing, zones, TLS, etc.)"
)
setup_idx=$(ask_select "Select Deployment Mode" 0 "${setup_options[@]}")
mode_simple=false
mode_lab=false
mode_advanced=false

if [[ $setup_idx -eq 0 ]]; then
  mode_simple=true
  echo
  echo -e "  ${TEXT_BOLD}${TEXT_PURPLE}Preparing Simple Deployment Defaults:${RESET}"
  echo -e "    ${TEXT_MUTED}Region:       ${RESET}us-west1 (Oregon)"
  echo -e "    ${TEXT_MUTED}Zone Letter:  ${RESET}b"
  echo -e "    ${TEXT_MUTED}Admin Access: ${RESET}0.0.0.0/0 (Any IP)"
  echo -e "    ${TEXT_MUTED}Nodes:        ${RESET}1 Conferencing Node"
  echo -e "    ${TEXT_MUTED}Node Sizing:  ${RESET}4 vCPU / 4 GB RAM (n2-highcpu-4)"
  echo -e "    ${TEXT_MUTED}TLS Certs:    ${RESET}Self-signed certificates (default)"
  echo
elif [[ $setup_idx -eq 1 ]]; then
  mode_lab=true
  echo
  echo -e "  ${TEXT_BOLD}${TEXT_PURPLE}Simple - Licensed/TLS Mode Context:${RESET}"
  echo -e "    ${TEXT_MUTED}Designed to be the quickest method to deploy Pexip Infinity end-to-end.${RESET}"
  echo -e "    ${TEXT_MUTED}Uses all Simple mode defaults but automatically prompts you to:${RESET}"
  echo -e "      ${TEXT_BOLD}1. Pexip License Key:${RESET} Activate your trial or production entitlement."
  echo -e "      ${TEXT_BOLD}2. TLS Certificates:${RESET} Provision browser-trusted Let's Encrypt certificates"
  echo -e "         automatically using a Cloudflare-managed domain and API token."
  echo -e "    ${TEXT_MUTED}Allows placing a secure TLS SIP call immediately on completion.${RESET}"
  echo
  echo -e "  ${TEXT_BOLD}${TEXT_PURPLE}Preparing Simple - Licensed/TLS Deployment Defaults:${RESET}"
  echo -e "    ${TEXT_MUTED}Region:       ${RESET}us-west1 (Oregon)"
  echo -e "    ${TEXT_MUTED}Zone Letter:  ${RESET}b"
  echo -e "    ${TEXT_MUTED}Admin Access: ${RESET}0.0.0.0/0 (Any IP)"
  echo -e "    ${TEXT_MUTED}Nodes:        ${RESET}1 Conferencing Node"
  echo -e "    ${TEXT_MUTED}Node Sizing:  ${RESET}4 vCPU / 4 GB RAM (n2-highcpu-4)"
  echo -e "    ${TEXT_MUTED}TLS Certs:    ${RESET}Let's Encrypt / Cloudflare DNS (prompted)"
  echo -e "    ${TEXT_MUTED}License Key:  ${RESET}Prompted"
  echo
else
  mode_advanced=true
fi

# ----------------------------------------------------------------------------
# Detect leftovers from a previous deploy.
#
# Most common cause: user ran setup.sh once, then opened a new Cloud Shell
# tab (which gets a fresh checkout with NO terraform.tfstate). Terraform
# now thinks nothing exists and tries to recreate everything, hitting
# `409 alreadyExists` on every name collision. Offer to wipe first.
# ----------------------------------------------------------------------------
state_present=0
[[ -s "${TF_DIR}/terraform.tfstate" ]] && state_present=1

if [[ $state_present -eq 0 ]]; then
  # Check ALL resource kinds this stack creates - any one of them present
  # without local state means re-apply will hit a 409 alreadyExists. The
  # most common case in practice is leftover images (1+ min each to create,
  # so they survive even when the user ctrl-Cs out of an apply early).
  results="$(spin "Checking for existing resources in $project_id" check_orphans "$project_id")"
  read -r inst_n net_n sa_n img_n addr_n fw_n <<< "$results"

  orphan_count=$((inst_n + net_n + sa_n + img_n + addr_n + fw_n))

  if [[ $orphan_count -gt 0 ]]; then
    echo
    print_info "Found existing pexip-quick-* resources in $project_id"
    print_info "There's no local terraform state, but your project already has:"
    [[ $inst_n -gt 0 ]] && print_info "  - $inst_n VM instance(s)"
    [[ $net_n  -gt 0 ]] && print_info "  - $net_n network(s)"
    [[ $sa_n   -gt 0 ]] && print_info "  - $sa_n service account(s)"
    [[ $img_n  -gt 0 ]] && print_info "  - $img_n copied image(s)"
    [[ $addr_n -gt 0 ]] && print_info "  - $addr_n reserved address(es)"
    [[ $fw_n   -gt 0 ]] && print_info "  - $fw_n firewall rule(s)"
    print_info "Re-deploying now would fail with 'alreadyExists' (HTTP 409) errors."
    echo
    if ask_confirm "Wipe these resources and start fresh?" "y"; then
      "${REPO_ROOT}/scripts/nuke.sh" "$project_id"
      echo
    else
      print_info "Skipping cleanup. If apply fails with 409, run: ${REPO_ROOT}/scripts/nuke.sh"
      print_info "Then re-run setup.sh."
    fi
  fi
fi

if [[ "$mode_simple" == "true" || "$mode_lab" == "true" ]]; then
  region="us-west1"
  zone_letter="a"
  mgmt_machine_type="n2-highcpu-4"
  conf_machine_type="n2-highcpu-4"
  print_info "Using default region: ${region}"
  print_info "Using default zone letter: ${zone_letter}"
else
  mgmt_machine_type="n2-highcpu-4"
  conf_machine_type="n2-highcpu-8"
  regions=("us-central1 (Iowa)" "us-east1 (South Carolina)" "us-west1 (Oregon)" "europe-west1 (Belgium)" "europe-west4 (Netherlands)" "asia-east1 (Taiwan)" "Other / Custom")
  region_idx=$(ask_select "Select GCP Region" 2 "${regions[@]}")
  if [[ $region_idx -eq 6 ]]; then
    region="$(ask_input 'Enter custom GCP Region' 'us-west1')"
  else
    selected_region="${regions[$region_idx]}"
    region="${selected_region%% *}"
  fi
  zone_letter="$(ask_input 'GCP Zone Letter (a/b/c/f/etc.)' 'a')"
fi

# ----------------------------------------------------------------------------
# Management access CIDR + Transcoding count
# ----------------------------------------------------------------------------
if [[ "$mode_simple" == "true" || "$mode_lab" == "true" ]]; then
  mgmt_cidr="0.0.0.0/0"
  xcode_count="1"
  print_info "Allowing Admin UI access from any IP (0.0.0.0/0)"
  print_info "Deploying 1 Conferencing Node"
else
  print_next_step "Admin UI & Infrastructure Settings"
  print_info "Pexip's web admin will only accept connections from the IP/CIDR you set here."
  print_info "Open https://ifconfig.me from the browser you'll log in with (NOT Cloud Shell) and grab that IP."
  print_info "Leave blank to allow any IP (0.0.0.0/0) - quick but insecure."
  mgmt_cidr="$(ask_input 'Admin UI Access CIDR (e.g., 1.2.3.4/32)' '')"
  [[ -z "$mgmt_cidr" ]] && mgmt_cidr="0.0.0.0/0"

  # ----------------------------------------------------------------------------
  # Transcoding count
  # ----------------------------------------------------------------------------
  xcode_count="$(ask_input 'Number of Conferencing Nodes' '1')"
fi

# ----------------------------------------------------------------------------
# Admin password + email
# ----------------------------------------------------------------------------
if [[ "$mode_simple" == "true" || "$mode_lab" == "true" ]]; then
  # Generate a secure 16-character alphanumeric password
  admin_password=$(set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
  contact_email=""
  print_info "Generated secure admin password: ${TEXT_PURPLE}••••••••${RESET} (shown at completion)"
else
  print_next_step "Pexip Management Node Credentials"
  print_info "Username will be 'admin'. Set a password (at least 8 characters):"
  while :; do
    pw1="$(ask_password 'Admin password')"
    pw2="$(ask_password 'Confirm password')"
    if [[ "$pw1" != "$pw2" ]]; then
      print_error "Passwords do not match. Try again."
    elif [[ ${#pw1} -lt 8 ]]; then
      print_error "Password must be at least 8 characters."
    else
      admin_password="$pw1"
      break
    fi
  done

  contact_email="$(ask_input 'Contact email Pexip stores with deployment' 'admin@example.com')"
fi

# ----------------------------------------------------------------------------
# Auto-detect latest Pexip images
#
# Pexip publishes images in pexip-product-images and grants read access to
# each individual image, but external users CANNOT list the project (no
# compute.images.list permission). So `gcloud compute images list` against
# it returns empty. We try the lookup anyway in case the user happens to
# have list permission, and fall back to known-good image names otherwise.
# ----------------------------------------------------------------------------
print_next_step "Pexip Infinity Software Images"
print_info "Looking up latest Pexip Infinity images in ${PEXIP_IMG_PROJECT}..."

latest_mgmt="$(spin "Querying mgmt-node images" \
  gcloud compute images list \
    --project="${PEXIP_IMG_PROJECT}" \
    --filter='name~^pexip-infinity-mgmt-node-' \
    --sort-by='~creationTimestamp' --limit=1 \
    --format='value(name)' || true)"

latest_conf="$(spin "Querying conf-node images" \
  gcloud compute images list \
    --project="${PEXIP_IMG_PROJECT}" \
    --filter='name~^pexip-infinity-conf-node-' \
    --sort-by='~creationTimestamp' --limit=1 \
    --format='value(name)' || true)"

if [[ -z "$latest_mgmt" || -z "$latest_conf" ]]; then
  print_info "Pexip's image project isn't list-able by external users; using built-in defaults."
  latest_mgmt="${latest_mgmt:-$PEXIP_DEFAULT_MGMT_IMAGE}"
  latest_conf="${latest_conf:-$PEXIP_DEFAULT_CONF_IMAGE}"
fi

if [[ "$mode_simple" == "true" || "$mode_lab" == "true" ]]; then
  mgmt_image="$latest_mgmt"
  conf_image="$latest_conf"
  print_info "Using Management Image:   ${mgmt_image}"
  print_info "Using Conferencing Image: ${conf_image}"
else
  print_info "Latest Management Image:   ${latest_mgmt}"
  print_info "Latest Conferencing Image: ${latest_conf}"
  echo
  mgmt_image="$(ask_input 'Use this Management image' "$latest_mgmt")"
  conf_image="$(ask_input 'Use this Conferencing image' "$latest_conf")"
  [[ -z "$mgmt_image" || -z "$conf_image" ]] && { print_error "Image names are required."; exit 1; }
fi

# ----------------------------------------------------------------------------
# Optional: Let's Encrypt + Cloudflare DNS-01
#
# Default is OFF (self-signed cert, browser warning). When the user opts in
# we collect domain + email + Cloudflare token, defaulting to LE STAGING so
# they can iterate without burning prod rate limits. Prod is a separate
# explicit yes/no after we've explained the rate-limit risk.
# ----------------------------------------------------------------------------
if [[ "$mode_simple" == "true" ]]; then
  enable_acme=false
  acme_domain=""
  acme_manager_hostname="pexip-mgr"
  acme_conf_hostname_prefix="pexip-conf"
  acme_email=""
  acme_use_production=false
  cloudflare_api_token=""
  cloudflare_zone_name=""
  manage_dns_records=true
  license_key=""
  print_info "Using self-signed certificates (default)"
else
  print_next_step "Pexip License Key (Entitlement Key)"
  print_info "To configure advanced platform features (VMRs, routing rules, etc.),"
  print_info "a Pexip license key is required. You can get a free 30-day trial at:"
  print_info "  https://www.pexip.com/start-trial"
  print_info "Press Enter to skip if you want to use the default self-signed fallback/register later."
  license_key="$(ask_password 'Pexip License Key')"

  print_next_step "TLS Certificates Setup"

  # For Lab mode, we always enable Let's Encrypt/Cloudflare. For Advanced mode, we ask.
  run_acme_setup=false
  if [[ "$mode_lab" == "true" ]]; then
    run_acme_setup=true
  else
    print_info "By default this stack uses self-signed certs (browsers will warn)."
    print_info "Optionally, get real Let's Encrypt certs via Cloudflare DNS-01 - you'll"
    print_info "need a Cloudflare-hosted domain and an API token with Zone.DNS:Edit."
    echo
    if ask_confirm "Enable Let's Encrypt + Cloudflare?" "n"; then
      run_acme_setup=true
    fi
  fi

  if [[ "$run_acme_setup" == "true" ]]; then
    enable_acme=true
    acme_domain="$(ask_input 'Base DNS domain (e.g. demo.example.com)' '')"
    [[ -z "$acme_domain" ]] && { print_error "acme_domain is required when ACME is enabled."; exit 1; }

    while :; do
      acme_manager_hostname="$(ask_input 'Manager short hostname under that domain' 'pexip-mgr')"
      acme_conf_hostname_prefix="$(ask_input 'Conf-node short-hostname prefix' 'pexip-conf')"
      acme_email="$(ask_input 'Email for the Let'\''s Encrypt account' "$contact_email")"

      echo
      print_info "Cloudflare API token is required. Create one at:"
      print_info "  https://dash.cloudflare.com/profile/api-tokens"
      print_info "Permissions required: Zone.DNS:Edit on the zone hosting ${acme_domain}"
      while :; do
        cloudflare_api_token="$(ask_password 'Cloudflare API token')"

        # Validate the token against Cloudflare BEFORE we commit to a 10-minute
        # apply.
        echo
        if CF_DNS_API_TOKEN="$cloudflare_api_token" ACME_DOMAIN="$acme_domain" \
           "${REPO_ROOT}/scripts/test-cloudflare-token.sh"; then
          break
        fi
        echo
        print_error "Cloudflare preflight failed. Paste a corrected token, or Ctrl-C to abort."
        print_info "Common fixes: re-copy the token (no leading/trailing whitespace), or"
        print_info "re-create at https://dash.cloudflare.com/profile/api-tokens with"
        print_info "Zone -> DNS -> Edit on the zone for ${acme_domain}."
        echo
      done

      echo
      acme_options=("stage  (recommended for first deploy - browser warning)" "prod   (browser-trusted - strict rate limits)")
      acme_selected=$(ask_select "Select Let's Encrypt Environment" 0 "${acme_options[@]}")
      if [[ $acme_selected -eq 0 ]]; then
        acme_use_production=false
        print_info "Using Let's Encrypt STAGING - cert WILL still trigger a browser warning."
        print_info "Flip to production later by editing terraform.tfvars (acme_use_production = true) and re-running terraform apply."
      else
        acme_use_production=true
        print_info "Using Let's Encrypt PRODUCTION - cert will be browser-trusted."
      fi

      echo
      if ask_confirm "Automatically create A and SIP/SIPS/Pexapp SRV records in Cloudflare?" "y"; then
        manage_dns_records=true
        cloudflare_zone_name="$(ask_input "Cloudflare zone name (leave empty if zone is exactly '${acme_domain}')" "")"
      else
        manage_dns_records=false
        cloudflare_zone_name=""
      fi

      # If managing DNS records, let's check for existing records now
      if [[ "$manage_dns_records" == "true" ]]; then
        echo
        print_info "Checking Cloudflare for existing DNS records matching these hostnames..."

        # Run clean-cloudflare-srv.py in check mode
        set +e
        CF_DNS_API_TOKEN="$cloudflare_api_token" \
        ACME_DOMAIN="$acme_domain" \
        ACME_ZONE_NAME="$cloudflare_zone_name" \
        ACME_MANAGER_HOSTNAME="$acme_manager_hostname" \
        ACME_CONF_HOSTNAME_PREFIX="$acme_conf_hostname_prefix" \
        python3 "${REPO_ROOT}/scripts/clean-cloudflare-srv.py" --check
        check_status=$?
        set -e

        if [[ $check_status -eq 2 ]]; then
          echo
          print_warning "Conflicting/existing DNS records were found in Cloudflare."
          print_info "What would you like to do?"
          conflict_options=(
            "Delete/Overwrite the existing records (Recommended if replacing a stale/failed deploy)"
            "Change hostnames (Go back and prompt for different hostnames)"
            "Abort setup"
          )
          conflict_selected=$(ask_select "Select Action" 0 "${conflict_options[@]}")

          if [[ $conflict_selected -eq 0 ]]; then
            echo
            print_info "Purging conflicting Cloudflare DNS records..."
            CF_DNS_API_TOKEN="$cloudflare_api_token" \
            ACME_DOMAIN="$acme_domain" \
            ACME_ZONE_NAME="$cloudflare_zone_name" \
            ACME_MANAGER_HOSTNAME="$acme_manager_hostname" \
            ACME_CONF_HOSTNAME_PREFIX="$acme_conf_hostname_prefix" \
            python3 "${REPO_ROOT}/scripts/clean-cloudflare-srv.py"
            break # Exit the hostname loop and proceed
          elif [[ $conflict_selected -eq 1 ]]; then
            echo
            print_info "Let's enter new hostnames."
            continue # Restart the loop to ask for hostnames again
          else
            print_error "Setup aborted by user."
            exit 1
          fi
        else
          # No conflicts found (check_status = 0) or check failed (ignore or print warning?)
          if [[ $check_status -ne 0 ]]; then
            print_warning "Unable to verify existing records on Cloudflare (exit code $check_status). Proceeding anyway."
          fi
          break # Exit the loop and proceed
        fi
      else
        break # Exit the loop and proceed
      fi
    done

    if [[ "$manage_dns_records" == "false" ]]; then
      echo
      print_info "DNS records you'll need to create after deploy completes:"
      print_info "  ${acme_manager_hostname}.${acme_domain}      -> Manager public IP"
      for i in $(seq 1 "${xcode_count}"); do
        print_info "  ${acme_conf_hostname_prefix}-${i}.${acme_domain}  -> Conferencing Node ${i} IP"
      done
      print_info "The DNS-01 challenge only requires the zone to be on Cloudflare; the"
      print_info "A records above are for clients reaching the nodes after deploy."
    fi
  else
    enable_acme=false
    acme_domain=""
    acme_manager_hostname="pexip-mgr"
    acme_conf_hostname_prefix="pexip-conf"
    acme_email=""
    acme_use_production=false
    cloudflare_api_token=""
    cloudflare_zone_name=""
    manage_dns_records=true
  fi
fi

# ----------------------------------------------------------------------------
# Query available zones and construct fallback list
# ----------------------------------------------------------------------------
print_info "Querying available zones in region ${region}..."
set +e
zones=($(gcloud compute zones list \
  --project="${project_id}" \
  --filter="region:(${region}) AND status:UP" \
  --format="value(name)" 2>/dev/null || true))
set -e

candidate_letters=()
for z in "${zones[@]}"; do
  candidate_letters+=("${z##*-}")
done

if [[ ${#candidate_letters[@]} -eq 0 ]]; then
  candidate_letters=("a" "b" "c")
fi

preferred_zone="${zone_letter}"
if [[ "$preferred_zone" == "any" ]]; then
  preferred_zone="a"
fi

reordered_letters=()
reordered_letters+=("$preferred_zone")
for l in $(printf '%s\n' "${candidate_letters[@]}" | sort); do
  if [[ "$l" != "$preferred_zone" ]]; then
    reordered_letters+=("$l")
  fi
done

print_info "Zone fallback sequence: $(IFS=,; echo "${reordered_letters[*]}")"

# ----------------------------------------------------------------------------
# Heads-up about Cloud Shell's idle timeout before the long wait starts.
# Apply takes 8-12 min; Cloud Shell kicks idle sessions at 20 min. If the
# session dies mid-apply the GCP project ends up with orphaned resources
# and the local state file is incomplete - recoverable, but no fun. Telling
# the user up-front beats explaining the recovery after the fact.
# ----------------------------------------------------------------------------
if [[ "${CLOUD_SHELL:-}" == "true" || -n "${DEVSHELL_PROJECT_ID:-}" ]]; then
  echo
  print_divider
  echo -e "  ${TEXT_BOLD}${TEXT_RED}⚠️  IMPORTANT: Cloud Shell Timeout Warning${RESET}"
  print_divider
  print_info "The next step (terraform apply) runs for 8-12 minutes."
  print_info "Cloud Shell disconnects idle sessions after about 20 minutes."
  print_info "DO NOT close this tab, and ensure your laptop does not sleep."
  print_info "To buy yourself extra runway, you can open a second Cloud Shell tab and run:"
  print_info "  ./scripts/keep-alive.sh"
  print_divider
  echo
  if [[ "$mode_simple" != "true" ]]; then
    if ! ask_confirm "Are you ready to begin the deployment?" "y"; then
      print_error "Deployment aborted by user."
      exit 0
    fi
  else
    print_info "Starting deployment automatically (Simple Mode)..."
    sleep 2
  fi
fi

# ----------------------------------------------------------------------------
# Enable GCP APIs
# ----------------------------------------------------------------------------
print_next_step "Deploying Infrastructure with Terraform"
print_info "Enabling required GCP APIs..."
spin "enabling compute.googleapis.com + iam.googleapis.com" \
  gcloud services enable compute.googleapis.com iam.googleapis.com --project "$project_id"

# ----------------------------------------------------------------------------
# Terraform
# ----------------------------------------------------------------------------
cd "$TF_DIR"
print_info "Running terraform init (downloading providers)..."
terraform init -input=false

# ----------------------------------------------------------------------------
# Deployment Loop (Tries fallback zones on capacity exhaustion)
# ----------------------------------------------------------------------------
apply_ok=0
for idx in "${!reordered_letters[@]}"; do
  current_letter="${reordered_letters[$idx]}"
  attempt_num=$((idx + 1))
  max_attempts=${#reordered_letters[@]}

  print_step "S1.5" "Attempting Deploy in Zone: ${region}-${current_letter} (Zone $attempt_num of $max_attempts)"

  # Write terraform.tfvars
  umask 077
  cat > "$TFVARS" <<EOF
# Generated by scripts/setup.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
project_id              = "${project_id}"
region                  = "${region}"
zone_letter             = "${current_letter}"
management_access_cidrs = ["${mgmt_cidr}"]
transcoding_node_count  = ${xcode_count}
management_machine_type  = "${mgmt_machine_type}"
transcoding_machine_type = "${conf_machine_type}"

pexip_admin_password = "${admin_password}"
pexip_contact_email  = "${contact_email}"

pexip_management_source_image   = "${mgmt_image}"
pexip_conferencing_source_image = "${conf_image}"

# TLS / ACME (see README "TLS certificates")
enable_acme               = ${enable_acme}
acme_use_production       = ${acme_use_production}
acme_domain               = "${acme_domain}"
acme_manager_hostname     = "${acme_manager_hostname}"
acme_conf_hostname_prefix = "${acme_conf_hostname_prefix}"
acme_email                = "${acme_email}"
cloudflare_api_token      = "${cloudflare_api_token}"
manage_dns_records        = ${manage_dns_records}
cloudflare_zone_name      = "${cloudflare_zone_name}"
pexip_domain            = "${acme_domain:-pexip.local}"
EOF
  umask 022

  print_success "Wrote $TFVARS (configured for zone ${current_letter})"

  # Write/update pexip-config.yaml
  LICENSE_KEY="$license_key" REPO_ROOT="$REPO_ROOT" PEXIP_DOMAIN="${acme_domain:-pexip.local}" python3 -c '
import os, re, shutil
license_key = os.environ.get("LICENSE_KEY", "")
repo_root = os.environ.get("REPO_ROOT", "")
domain = os.environ.get("PEXIP_DOMAIN", "pexip.local")
yaml_path = os.path.join(repo_root, "pexip-config.yaml")
example_path = os.path.join(repo_root, "pexip-config.example.yaml")
if not os.path.exists(yaml_path) and os.path.exists(example_path):
    shutil.copy(example_path, yaml_path)
if os.path.exists(yaml_path):
    with open(yaml_path, "r", encoding="utf-8") as f:
        content = f.read()
    if license_key:
        content = re.sub(r"^(\s*license_key\s*:)\s*.*$", lambda m: f"{m.group(1)} \"{license_key}\"", content, flags=re.MULTILINE)
    else:
        sq = chr(39)
        pattern = r"^\s*license_key\s*:\s*[\"" + sq + r"]?([^\"" + sq + r"\s]+)[\"" + sq + r"]?\s*$"
        match = re.search(pattern, content, flags=re.MULTILINE)
        if not match or not match.group(1).strip():
            content = re.sub(r"^(\s*license_key\s*:)\s*.*$", lambda m: f"{m.group(1)} \"\"", content, flags=re.MULTILINE)

    if domain:
        content = content.replace("yourdomain.com", domain)
        content = content.replace("yourdomain\\\\.com", domain.replace(".", "\\\\."))
        content = content.replace("pexip.local", domain)

    with open(yaml_path, "w", encoding="utf-8") as f:
        f.write(content)
'
  print_success "Updated pexip-config.yaml for domain/licensing"

  echo
  print_info "Running terraform apply in ${region}-${current_letter}..."
  print_info "This takes ~8-12 minutes total on success."
  echo

  # Start the funny progress loop in the background
  funny_progress_loop &
  loop_pid=$!

  cleanup_loop() {
    kill "$loop_pid" 2>/dev/null || true
    wait "$loop_pid" 2>/dev/null || true
  }
  trap cleanup_loop EXIT INT TERM

  apply_log="$(mktemp)"
  zone_apply_ok=0
  apply_attempts=3

  for attempt in $(seq 1 $apply_attempts); do
    echo
    echo "==> terraform apply (attempt $attempt of $apply_attempts in zone ${current_letter})...."
    set +e
    terraform apply -auto-approve -parallelism=4 2>&1 | tee "$apply_log"
    apply_rc=$?
    set -e

    if [[ $apply_rc -eq 0 ]]; then
      zone_apply_ok=1
      break
    fi

    # Check if capacity issue (fail fast to next zone)
    if grep -q -E "ZONE_RESOURCE_POOL_EXHAUSTED|does not have enough resources|is currently unavailable" "$apply_log"; then
      print_info "Detected resource exhaustion in zone ${region}-${current_letter}."
      break
    fi

    if [[ $attempt -lt $apply_attempts ]]; then
      print_error_banner "⚠️  Terraform Apply Failed (Attempt $attempt of $apply_attempts)" \
                         "Retrying in 20 seconds..." \
                         "$TEXT_RED"
      sleep 20
    fi
  done

  # Fallback for standard apply attempts (refresh=false) if transient
  if [[ $zone_apply_ok -eq 0 ]] && ! grep -q -E "ZONE_RESOURCE_POOL_EXHAUSTED|does not have enough resources|is currently unavailable" "$apply_log"; then
    print_error_banner "⚠️  Standard Apply Attempts Failed" \
                       "Retrying one final time without state refresh (fast check)..." \
                       "$TEXT_PURPLE"
    echo "==> terraform apply -refresh=false..."
    set +e
    terraform apply -auto-approve -parallelism=4 -refresh=false 2>&1 | tee "$apply_log"
    apply_rc=$?
    set -e
    if [[ $apply_rc -eq 0 ]]; then
      zone_apply_ok=1
    fi
  fi

  cleanup_loop
  trap - EXIT INT TERM

  if [[ $zone_apply_ok -eq 1 ]]; then
    apply_ok=1
    rm -f "$apply_log"
    break
  else
    if grep -q -E "ZONE_RESOURCE_POOL_EXHAUSTED|does not have enough resources|is currently unavailable" "$apply_log"; then
      rm -f "$apply_log"
      print_error_banner "⚠️  Capacity Exhausted in ${region}-${current_letter}" \
                         "Automatically falling back to the next zone in sequence..." \
                         "$TEXT_PURPLE"
      sleep 5
    else
      # Non-capacity failure: clean up and exit
      rm -f "$apply_log"
      print_error_banner "✖  Terraform Deployment Failed" \
                         "An error occurred that is not related to capacity." \
                         "$TEXT_RED"
      exit 1
    fi
  fi
done

if [[ $apply_ok -ne 1 ]]; then
  print_error_banner "✖  All Fallback Zones Exhausted" \
                     "No capacity was found in any of the zones in region ${region}." \
                     "$TEXT_RED"
  exit 1
fi

# Clean up unused/temporary self-signed certificates if TLS was enabled
if [[ "$enable_acme" == "true" && "${apply_ok:-0}" == "1" ]]; then
  echo
  print_info "Checking Python dependencies for certificate cleanup..."
  if ! python3 -c "import requests" 2>/dev/null; then
    print_info "Installing 'requests' library inside user space..."
    python3 -m pip install --user -q requests || true
  fi
  print_info "Cleaning up unused/temporary self-signed certificates from the Pexip keystore..."
  # Run inside TF_DIR so cleanup-certs.py can find the terraform state and tfvars
  ( cd "$TF_DIR" && python3 "${REPO_ROOT}/scripts/cleanup-certs.py" --delete-all || true )
fi

# Retrieve Management Node URL and TLS status from Terraform
management_admin_url="$(terraform output -raw management_admin_url 2>/dev/null || true)"
tls_status="$(terraform output -raw tls_status 2>/dev/null || true)"

# Helper function to print the final credentials card and summary
print_final_summary() {
  # Print the premium credentials card
  print_credentials_card \
    "${management_admin_url:-https://<ip-address>/admin/}" \
    "admin" \
    "${admin_password}" \
    "${tls_status:-Self-signed}"

  # Surface additional instructions for Staging cert if applicable
  if [[ "$tls_status" == *STAGING* ]]; then
    print_info "Action: open the Admin URL, accept the browser warning ONCE to verify"
    print_info "the deploy works end-to-end, then re-run setup or edit terraform.tfvars"
    print_info "and set acme_use_production = true to get a browser-trusted cert."
    echo
  fi

  print_info "Note: Conferencing Node status can take up to 10 minutes to reflect as healthy in the Admin UI while services initialize."
  print_success "Open the Admin URL above in your browser to get started."
  print_info "A summary file has been saved to: ${TEXT_UNDERLINE}pexip-deployment-info.md${RESET}"
  print_info "Keep this file safe! It contains your login credentials and instructions"
  print_info "on how to back up your state file to run the destroy command later."
  echo
}

# Generate the downloadable deployment info summary markdown file
cat <<EOF > "${REPO_ROOT}/pexip-deployment-info.md"
# Pexip Infinity Deployment Summary

Successfully deployed on Google Cloud Platform!

## 🔐 Credentials & Access Info
* **Admin UI URL**: ${management_admin_url:-https://<ip-address>/admin/}
* **Username**: admin
* **Password**: ${admin_password}
* **TLS Certificate**: ${tls_status:-Self-signed}

*Note: Conferencing Node status can take up to 10 minutes to reflect as healthy in the Admin UI while services initialize.*

---

## 🗑️ How to Destroy/Teardown this Deployment Later
To clean up all GCP resources and stop billing, run the destroy script from the repository root:
\`\`\`bash
./scripts/destroy.sh
\`\`\`

### ⚠️ CRITICAL: Preserving your Terraform State
Terraform tracks the deployed GCP resources using the state file:
\`terraform/terraform.tfstate\`

**If you lose this file, Terraform will not know which resources were created, and running \`./scripts/destroy.sh\` will not work automatically.**

1. **If using Google Cloud Shell**:
   * Google Cloud Shell persists your home directory across sessions. As long as you log back into the same Google account and open Cloud Shell, this repository and your \`terraform/terraform.tfstate\` file will still be here. Just navigate to this repository and run \`./scripts/destroy.sh\`.
2. **If you are switching to a new shell, machine, or account**:
   * You **MUST** back up the \`terraform/terraform.tfstate\` file (and \`terraform/terraform.tfvars\`).
   * Download the \`terraform.tfstate\` file to your computer.
   * If you need to teardown later from a fresh setup: clone this repository, restore the \`terraform/terraform.tfstate\` and \`terraform/terraform.tfvars\` files to their respective locations, and run \`./scripts/destroy.sh\`.
EOF

# ----------------------------------------------------------------------------
# Stage 2 Configuration Prompt
# ----------------------------------------------------------------------------
print_step "Stage 2" "Declarative Platform Configuration"
print_info "You can automatically bootstrap your license, VMRs, users, and routing"
print_info "rules now using the declarative configuration file (pexip-config.yaml)."
echo

if ask_confirm "Automatically run configuration sync now?" "y"; then
  echo
  print_info "Running Stage 2 Configuration Sync..."
  if "${REPO_ROOT}/scripts/configure-platform.sh"; then
    echo
    print_divider
    echo -e "  ${TEXT_GREEN}${TEXT_BOLD}✔  Deploy & Configuration complete!${RESET}"
    print_divider
    echo
    print_final_summary
  else
    echo
    print_error "Stage 2 Configuration failed. You can re-run it later with: ./scripts/configure-platform.sh"
    echo
    print_divider
    echo -e "  ${TEXT_GREEN}${TEXT_BOLD}✔  Deploy complete (Configuration failed)!${RESET}"
    print_divider
    echo
    print_final_summary
  fi
else
  echo
  print_info "Skipping automatic configuration sync."
  print_info "You can manually customize 'pexip-config.yaml' and sync it later by running:"
  print_info "  ./scripts/configure-platform.sh"
  echo
  print_divider
  echo -e "  ${TEXT_GREEN}${TEXT_BOLD}✔  Deploy complete!${RESET}"
  print_divider
  echo
  print_final_summary
fi
echo
