#!/usr/bin/env bash
# ============================================================================
# install-cert.sh - import Let's Encrypt certs into Pexip's keystore via the
# bulk certificates_import endpoint, then assign each cert to the right
# node by PATCHing the node's tls_certificate field.
#
# Called by null_resource.install_acme_certs in terraform/main.tf, only
# when var.enable_acme is true. Side-effect only: nothing tracked in
# terraform state. Same pattern as register-conf-nodes.sh - Pexip-internal
# objects stay out of tfstate so `terraform destroy` doesn't need to
# reach the Manager API to clean them up.
#
# Endpoints used (verified against Pexip Infinity 40.x schema):
#   POST /api/admin/command/v1/platform/certificates_import/
#     Body: {bundle: "<leaf>\n<chain>\n<private_key>"}
#     Pexip parses the bundle server-side, creates a tls_certificate record.
#   GET /api/admin/configuration/v1/tls_certificate/?subject_name=<fqdn>
#     Returns the created cert's resource_uri.
#   PATCH /api/admin/configuration/v1/management_vm/1/
#     Body: {tls_certificate: <uri>, alternative_fqdn: <fqdn>}
#     alternative_fqdn makes the Manager identify itself with the new
#     FQDN in self-generated links - otherwise browsers may reject redirects
#     because the cert says X but the page link says Y.
#   PATCH /api/admin/configuration/v1/worker_vm/<id>/
#     Body: {tls_certificate: <uri>}
#     Conf nodes don't have alternative_fqdn - their identity is the
#     node name itself, and SAN coverage handles the multi-host case.
#
# Idempotency: GET by subject_name before import. If the cert exists, skip
# the import POST and go straight to assignment. (For renewal, we'd PATCH
# the existing tls_certificate record - left as a future improvement; for
# now, renewals require the user to delete the old cert in the admin UI
# or via Terraform destroy of acme_certificate.)
#
# Inputs (env vars):
#   PEXIP_MANAGER_IP     - Manager public IP (admin UI reachable).
#   PEXIP_API_ROOT       - optional override for testing (default https://$IP).
#   PEXIP_ADMIN_PASSWORD - admin password for HTTP Basic auth.
#   MANAGER_FQDN         - DNS name on the Manager's cert.
#   MANAGER_CERT_PEM     - Manager leaf cert PEM.
#   MANAGER_ISSUER_PEM   - Manager issuer chain PEM.
#   MANAGER_KEY_PEM      - Manager private key PEM.
#   CONF_FQDNS_CSV       - comma-separated conf node FQDNs in deploy order.
#   CONF_CERT_PEM        - conf node SAN cert PEM.
#   CONF_ISSUER_PEM      - conf cert issuer chain PEM.
#   CONF_KEY_PEM         - conf cert private key PEM.
# ============================================================================
set -euo pipefail

: "${PEXIP_MANAGER_IP:?must be set}"
: "${PEXIP_ADMIN_PASSWORD:?must be set}"
: "${MANAGER_FQDN:?must be set}"
: "${MANAGER_CERT_PEM:?must be set}"
: "${MANAGER_KEY_PEM:?must be set}"
CONF_FQDNS_CSV="${CONF_FQDNS_CSV:-}"
MANAGER_ISSUER_PEM="${MANAGER_ISSUER_PEM:-}"
CONF_CERT_PEM="${CONF_CERT_PEM:-}"
CONF_ISSUER_PEM="${CONF_ISSUER_PEM:-}"
CONF_KEY_PEM="${CONF_KEY_PEM:-}"

# PEXIP_API_ROOT can override the base URL for tests against a mock server.
# Default builds the real HTTPS URL from PEXIP_MANAGER_IP.
PEXIP_API_ROOT="${PEXIP_API_ROOT:-https://${PEXIP_MANAGER_IP}}"
CONFIG_BASE="${PEXIP_API_ROOT}/api/admin/configuration/v1"
COMMAND_BASE="${PEXIP_API_ROOT}/api/admin/command/v1"

pexip_curl() {
  curl --silent --show-error --insecure \
       --user "admin:${PEXIP_ADMIN_PASSWORD}" \
       --max-time 30 \
       --retry 3 --retry-delay 5 --retry-connrefused \
       --write-out '\n%{http_code}\n' \
       "$@"
}

split_response() {
  local body_file="$1"
  local raw="$(cat)"
  printf '%s' "${raw%$'\n'*}" > "$body_file"
  printf '%s' "${raw##*$'\n'}"
}

err() { echo "ERROR: $*" >&2; exit 1; }

fmt_status() {
  local s="$1"
  if [[ "$s" == "000" || "$s" == "0" || -z "$s" ]]; then
    echo "Connection Failed (Pexip Manager API unreachable or booting)"
  else
    echo "HTTP $s"
  fi
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# find_cert_uri <subject_name> <cert_pem> -> echoes resource_uri (or empty)
# GET /tls_certificate/?subject_name=<fqdn> and pick the record with the matching fingerprint.
find_cert_uri() {
  local subject="$1"
  local cert_pem="$2"

  if [[ -z "$cert_pem" ]]; then
    return
  fi

  # Compute target certificate fingerprint
  local target_fingerprint
  target_fingerprint="$(echo "$cert_pem" | openssl x509 -noout -fingerprint 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"

  if [[ -z "$target_fingerprint" ]]; then
    return
  fi

  local lookup="${tmpdir}/cert-lookup-$(echo "$subject" | tr -c 'a-zA-Z0-9' '_').json"
  local status
  status="$(pexip_curl "${CONFIG_BASE}/tls_certificate/?subject_name=${subject}" | split_response "$lookup")"
  [[ "$status" == "200" ]] || err "tls_certificate GET (subject=${subject}) failed ($(fmt_status "$status")): $(cat "$lookup")"

  # Iterate over matching certificates and compare fingerprints
  local count
  count="$(jq '.objects | length' "$lookup")"
  for ((i=0; i<count; i++)); do
    local uri cert_data
    uri="$(jq -r ".objects[$i].resource_uri" "$lookup")"
    cert_data="$(jq -r ".objects[$i].certificate" "$lookup")"

    if [[ -n "$cert_data" && "$cert_data" != "null" ]]; then
      local fp
      fp="$(echo "$cert_data" | openssl x509 -noout -fingerprint 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
      if [[ "$fp" == "$target_fingerprint" ]]; then
        echo "$uri"
        return
      fi
    fi
  done
}

# import_or_find <subject_name> <leaf_pem> <chain_pem> <key_pem> -> echoes resource_uri
# Imports the cert via the bulk certificates_import endpoint, then looks up
# the created record by subject_name. If a cert with the same subject_name
# and fingerprint already exists, skip the import and reuse it.
import_or_find() {
  local subject="$1" leaf="$2" chain="$3" key="$4"

  local existing
  existing="$(find_cert_uri "$subject" "$leaf")"
  if [[ -n "$existing" ]]; then
    echo "    tls_certificate for ${subject} already exists (${existing}); reusing" >&2
    echo "$existing"
    return
  fi

  # certificates_import expects a single PEM blob: leaf, chain, then key.
  # Pexip parses the components server-side and creates the cert record.
  local bundle
  bundle="$(printf '%s\n%s\n%s\n' "$leaf" "$chain" "$key")"

  echo "    importing tls_certificate for ${subject}..." >&2
  local status
  status="$(pexip_curl -X POST \
    -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg b "$bundle" '{bundle:$b}')" \
    "${COMMAND_BASE}/platform/certificates_import/" | split_response "${tmpdir}/import.json")"

  case "$status" in
    200|201|202|204)
      :  # success
      ;;
    *)
      err "certificates_import POST failed ($(fmt_status "$status")): $(cat "${tmpdir}/import.json")"
      ;;
  esac

  # certificates_import doesn't reliably return the new record's URI in the
  # response body across Pexip versions, so re-GET by subject_name.
  local uri
  uri="$(find_cert_uri "$subject" "$leaf")"
  [[ -n "$uri" ]] || err "tls_certificate for ${subject} imported but GET by subject_name returned nothing"
  echo "$uri"
}

# assign_cert <node_endpoint> <node_name> <patch_payload_json>
# Look up the node by name, PATCH its record. patch_payload_json is the
# full JSON object - so callers can include alternative_fqdn for the
# Manager but not for conf nodes.
# Special case: management_vm is a singleton in Pexip, so name filter is
# bypassed and the first object is always used (its name is typically
# "Management Node", not matching the hostname VM name).
assign_cert() {
  local endpoint="$1" name="$2" patch="$3"
  local lookup="${tmpdir}/${endpoint}-lookup.json"
  local status

  if [[ "$endpoint" == "management_vm" ]]; then
    status="$(pexip_curl "${CONFIG_BASE}/${endpoint}/" | split_response "$lookup")"
    [[ "$status" == "200" ]] || err "${endpoint} GET failed ($(fmt_status "$status")): $(cat "$lookup")"

    local node_uri
    node_uri="$(jq -r '.objects[0].resource_uri // empty' "$lookup")"
    [[ -n "$node_uri" ]] || err "${endpoint} not found in Pexip"
  else
    status="$(pexip_curl "${CONFIG_BASE}/${endpoint}/?name=${name}" | split_response "$lookup")"
    [[ "$status" == "200" ]] || err "${endpoint} GET (${name}) failed ($(fmt_status "$status")): $(cat "$lookup")"

    local node_uri
    node_uri="$(jq -r --arg name "$name" \
      '.objects[] | select(.name == $name) | .resource_uri' \
      "$lookup" | head -1)"
    [[ -n "$node_uri" ]] || err "${endpoint} ${name} not found in Pexip - register-conf-nodes.sh must run first"
  fi

  status="$(pexip_curl -X PATCH \
    -H 'Content-Type: application/json' \
    --data "$patch" \
    "${PEXIP_API_ROOT}${node_uri}" | split_response "${tmpdir}/assign.json")"
  [[ "$status" =~ ^(200|202|204)$ ]] || err "${endpoint} ${name} PATCH failed ($(fmt_status "$status")): $(cat "${tmpdir}/assign.json")"
  echo "    assigned cert -> ${endpoint}/${name}" >&2
}

# ----------------------------------------------------------------------------
# Manager cert
# ----------------------------------------------------------------------------
echo "==> Importing Manager cert (${MANAGER_FQDN})..." >&2
manager_tls_uri="$(import_or_find \
  "$MANAGER_FQDN" \
  "$MANAGER_CERT_PEM" \
  "$MANAGER_ISSUER_PEM" \
  "$MANAGER_KEY_PEM")"

echo "==> Assigning Manager cert + setting alternative_fqdn..." >&2
# alternative_fqdn makes the Manager's self-references (links, redirects,
# the UI banner) match the cert's identity. Without it, the cert says
# pexip-mgr.demo.example.com but the page tells your browser to redirect
# to pexip-mgr.pexip.local, breaking the trust chain.
manager_patch="$(jq -nc \
  --arg t "$manager_tls_uri" \
  --arg f "$MANAGER_FQDN" \
  '{tls_certificate:$t, alternative_fqdn:$f}')"
assign_cert management_vm "pexip-mgr" "$manager_patch"

# ----------------------------------------------------------------------------
# Conf node cert (one SAN cert covering every conf FQDN)
# ----------------------------------------------------------------------------
if [[ -n "$CONF_FQDNS_CSV" && -n "$CONF_CERT_PEM" ]]; then
  conf_cn="${CONF_FQDNS_CSV%%,*}"
  echo "==> Importing Conferencing-Node SAN cert (CN=${conf_cn})..." >&2
  conf_tls_uri="$(import_or_find \
    "$conf_cn" \
    "$CONF_CERT_PEM" \
    "$CONF_ISSUER_PEM" \
    "$CONF_KEY_PEM")"

  # Same cert URI on every conf node. They share an identity for SIP routing
  # (same system_location); sharing the cert makes the set round-robinnable.
  # No alternative_fqdn here - worker_vm doesn't have that field; node
  # identity comes from its name + the cert's SAN list.
  echo "==> Assigning Conferencing-Node cert..." >&2
  IFS=',' read -ra fqdns <<<"$CONF_FQDNS_CSV"
  for i in "${!fqdns[@]}"; do
    fqdn="${fqdns[i]}"
    node_name="${fqdn%%.*}"
    conf_patch="$(jq -nc --arg t "$conf_tls_uri" '{tls_certificate:$t}')"
    assign_cert worker_vm "$node_name" "$conf_patch"
  done
fi

echo "==> Cert install complete." >&2
