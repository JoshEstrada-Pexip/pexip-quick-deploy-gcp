#!/usr/bin/env bash
# ============================================================================
# register-conf-nodes.sh — register Conferencing Nodes with a running
# Pexip Management Node and emit their bootstrap configs.
#
# Replaces what the Pexip provider's pexip_infinity_system_location and
# pexip_infinity_worker_vm resources did, but as a one-shot side effect so
# terraform doesn't keep those values in state (where they were causing
# destroy-time failures: terraform was trying to refresh / DELETE them via
# the Manager API, but the admin firewall blocks Cloud Shell, so the whole
# destroy would hang before any GCP resource got cleaned up).
#
# Idempotent: if the system_location or a worker_vm with the requested name
# already exists, we reuse it (GET to look up the existing record) instead
# of failing on a 409 Conflict.
#
# Inputs (env vars):
#   PEXIP_MANAGER_IP        — Manager VM public IP (caller has already
#                             verified the admin UI is reachable).
#   PEXIP_ADMIN_PASSWORD    — admin password for HTTP Basic auth.
#   PEXIP_CONF_NODES_JSON   — JSON array of conf nodes to register. Each
#                             element must have:
#                               name, hostname, domain, address, netmask,
#                               gateway, password_hash
#                             and optional:
#                               static_nat_address
#   PEXIP_SYSTEM_LOCATION   — system_location name (default "Primary").
#   PEXIP_DNS_SERVERS       — comma-separated DNS server IPs to register and
#                             attach to the system_location. Default "8.8.8.8"
#                             (matches the Manager bootstrap). Without this
#                             the system_location has no DNS servers and
#                             conf nodes can't resolve anything at runtime,
#                             which manifests as "node syncs but media /
#                             outbound APIs are broken".
#   PEXIP_NTP_SERVERS       — comma-separated NTP server hostnames. Default
#                             "pool.ntp.org". Same rationale as DNS.
#   PEXIP_OUT_DIR           — where to write conf-configs.json. Default cwd.
#
# Output:
#   $PEXIP_OUT_DIR/conf-configs.json  — JSON: {"configs": [<base64 blob>, ...]}
#   stdout                            — same JSON, in case caller wants it.
#
# Exit codes:
#   0 success; non-zero on any irrecoverable error (auth fail, API down,
#   malformed input, etc.) — Manager-API failures DO retry first.
# ============================================================================
set -euo pipefail

: "${PEXIP_MANAGER_IP:?must be set}"
: "${PEXIP_ADMIN_PASSWORD:?must be set}"
: "${PEXIP_CONF_NODES_JSON:?must be set (JSON array)}"
PEXIP_SYSTEM_LOCATION="${PEXIP_SYSTEM_LOCATION:-Primary}"
PEXIP_DNS_SERVERS="${PEXIP_DNS_SERVERS:-8.8.8.8}"
PEXIP_NTP_SERVERS="${PEXIP_NTP_SERVERS:-pool.ntp.org}"
PEXIP_OUT_DIR="${PEXIP_OUT_DIR:-.}"

PEXIP_API_ROOT="${PEXIP_API_ROOT:-https://${PEXIP_MANAGER_IP}}"
API_BASE="${PEXIP_API_ROOT}/api/admin/configuration/v1"

# curl wrapper: HTTP basic auth, self-signed TLS (always the case for a fresh
# Pexip Manager), 30s timeout, retry on transient 5xx/timeouts.
pexip_curl() {
  curl --silent --show-error --insecure \
       --user "admin:${PEXIP_ADMIN_PASSWORD}" \
       --max-time 30 \
       --retry 3 --retry-delay 5 --retry-connrefused \
       --write-out '\n%{http_code}\n' \
       "$@"
}

# Split a pexip_curl output into body and status code. Reads stdin, writes
# body to $1 (filename), echoes status code on stdout.
split_response() {
  local body_file="$1"
  local raw="$(cat)"
  # Last line is the status, rest is body. -1 trims the trailing newline.
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

# ensure_by_address <endpoint> <address>
# Looks up a record by its `address` field on the given API endpoint
# (e.g. dns_server, ntp_server). If found, echoes its resource_uri. If
# not, POSTs a minimal {address: <address>} create payload and re-GETs.
# Idempotent: re-running with the same address always returns the same URI.
ensure_by_address() {
  local endpoint="$1" address="$2"
  local lookup_file="${tmpdir}/lookup-$(echo "$endpoint$address" | tr -c 'a-zA-Z0-9' '_').json"

  local status
  status="$(pexip_curl "${API_BASE}/${endpoint}/?address=${address}" | split_response "$lookup_file")"
  [[ "$status" == "200" ]] || err "${endpoint} GET failed ($(fmt_status "$status")): $(cat "$lookup_file")"

  local uri
  uri="$(jq -r --arg addr "$address" \
    '.objects[] | select(.address == $addr) | .resource_uri' \
    "$lookup_file" | head -1)"

  if [[ -z "$uri" ]]; then
    status="$(pexip_curl -X POST \
      -H 'Content-Type: application/json' \
      --data "$(jq -nc --arg addr "$address" '{address:$addr, description:"Created by pexip-quick-deploy"}')" \
      "${API_BASE}/${endpoint}/" | split_response "${lookup_file}.create")"
    [[ "$status" =~ ^(201|200)$ ]] || err "${endpoint} POST failed ($(fmt_status "$status")): $(cat "${lookup_file}.create")"

    # Re-GET to retrieve the URI (POST body is the bootstrap blob for
    # worker_vm but for these scalar resources it's empty, so GET is the
    # only way to get the URI consistently).
    pexip_curl "${API_BASE}/${endpoint}/?address=${address}" | split_response "$lookup_file" >/dev/null
    uri="$(jq -r --arg addr "$address" \
      '.objects[] | select(.address == $addr) | .resource_uri' \
      "$lookup_file" | head -1)"
    [[ -n "$uri" ]] || err "${endpoint} ${address} was created but GET still returns nothing"
  fi
  echo "$uri"
}

# Comma-separated string -> JSON array of resource URIs by ensuring each
# entry exists at the given endpoint. Used for dns_server and ntp_server.
csv_to_uri_array() {
  local endpoint="$1" csv="$2"
  local out='[]'
  IFS=',' read -ra entries <<<"$csv"
  for entry in "${entries[@]}"; do
    entry="${entry// /}" # trim whitespace
    [[ -z "$entry" ]] && continue
    local uri
    uri="$(ensure_by_address "$endpoint" "$entry")"
    echo "  + ${endpoint}: ${entry} -> ${uri}" >&2
    out="$(jq -c --arg u "$uri" '. + [$u]' <<<"$out")"
  done
  echo "$out"
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# ----------------------------------------------------------------------------
# 1. Register DNS + NTP servers as their own resources first, since the
#    system_location references them by resource_uri. Without these, conf
#    nodes inherit empty DNS/NTP and can't resolve anything at runtime
#    (the symptom: node syncs OK but outbound calls/lookups silently fail).
# ----------------------------------------------------------------------------
echo "==> Registering DNS servers..." >&2
dns_uris_json="$(csv_to_uri_array dns_server "$PEXIP_DNS_SERVERS")"

echo "==> Registering NTP servers..." >&2
ntp_uris_json="$(csv_to_uri_array ntp_server "$PEXIP_NTP_SERVERS")"

# ----------------------------------------------------------------------------
# 2. Ensure system_location exists with DNS+NTP attached. If it exists but
#    is missing DNS/NTP (e.g. from a previous run on older code), PATCH it
#    to fix - otherwise the conf nodes registered against it will inherit
#    the bug.
# ----------------------------------------------------------------------------
echo "==> Looking up system_location '${PEXIP_SYSTEM_LOCATION}'..." >&2

status="$(pexip_curl "${API_BASE}/system_location/?name=${PEXIP_SYSTEM_LOCATION}" | split_response "${tmpdir}/sysloc.json")"
[[ "$status" == "200" ]] || err "system_location GET failed ($(fmt_status "$status")): $(cat "${tmpdir}/sysloc.json")"

sysloc_uri="$(jq -r --arg name "$PEXIP_SYSTEM_LOCATION" \
  '.objects[] | select(.name == $name) | .resource_uri' \
  "${tmpdir}/sysloc.json" | head -1)"

sysloc_payload="$(jq -nc \
  --arg name "$PEXIP_SYSTEM_LOCATION" \
  --argjson dns "$dns_uris_json" \
  --argjson ntp "$ntp_uris_json" \
  '{name:$name, description:"Created by pexip-quick-deploy", dns_servers:$dns, ntp_servers:$ntp}')"

if [[ -z "$sysloc_uri" ]]; then
  echo "    not found, creating with DNS+NTP attached..." >&2
  status="$(pexip_curl -X POST \
    -H 'Content-Type: application/json' \
    --data "$sysloc_payload" \
    "${API_BASE}/system_location/" | split_response "${tmpdir}/sysloc-create.json")"
  [[ "$status" =~ ^(201|200)$ ]] || err "system_location POST failed ($(fmt_status "$status")): $(cat "${tmpdir}/sysloc-create.json")"

  # POST returns a Location header but our curl wrapper isn't capturing it;
  # GET again to grab the resource_uri.
  status="$(pexip_curl "${API_BASE}/system_location/?name=${PEXIP_SYSTEM_LOCATION}" | split_response "${tmpdir}/sysloc.json")"
  sysloc_uri="$(jq -r --arg name "$PEXIP_SYSTEM_LOCATION" \
    '.objects[] | select(.name == $name) | .resource_uri' \
    "${tmpdir}/sysloc.json" | head -1)"
  [[ -n "$sysloc_uri" ]] || err "system_location was created but GET still returns nothing"
else
  # Existing system_location - check if DNS/NTP need patching. We always
  # PATCH if either is empty or differs from our request, so re-running
  # heals a system_location created by older code.
  current_dns="$(jq -r --arg name "$PEXIP_SYSTEM_LOCATION" \
    '.objects[] | select(.name == $name) | .dns_servers | length' \
    "${tmpdir}/sysloc.json")"
  current_ntp="$(jq -r --arg name "$PEXIP_SYSTEM_LOCATION" \
    '.objects[] | select(.name == $name) | .ntp_servers | length' \
    "${tmpdir}/sysloc.json")"
  requested_dns_count="$(jq -r 'length' <<<"$dns_uris_json")"
  requested_ntp_count="$(jq -r 'length' <<<"$ntp_uris_json")"
  if [[ "$current_dns" != "$requested_dns_count" || "$current_ntp" != "$requested_ntp_count" ]]; then
    echo "    existing system_location is missing DNS/NTP (got dns=$current_dns ntp=$current_ntp; want $requested_dns_count/$requested_ntp_count) - patching..." >&2
    patch_payload="$(jq -nc \
      --argjson dns "$dns_uris_json" \
      --argjson ntp "$ntp_uris_json" \
      '{dns_servers:$dns, ntp_servers:$ntp}')"
    status="$(pexip_curl -X PATCH \
      -H 'Content-Type: application/json' \
      --data "$patch_payload" \
      "${PEXIP_API_ROOT}${sysloc_uri}" | split_response "${tmpdir}/sysloc-patch.json")"
    [[ "$status" =~ ^(200|202|204)$ ]] || err "system_location PATCH failed ($(fmt_status "$status")): $(cat "${tmpdir}/sysloc-patch.json")"
  fi
fi
echo "    system_location URI: ${sysloc_uri}" >&2

# ----------------------------------------------------------------------------
# 2. For each conf node: GET by name, POST if missing. Capture response body
#    (which IS the bootstrap config blob).
# ----------------------------------------------------------------------------
configs_array='[]'

while IFS= read -r node_json; do
  name="$(jq -r '.name' <<<"$node_json")"
  echo "==> Registering conferencing node '${name}'..." >&2

  # Check if it already exists.
  status="$(pexip_curl "${API_BASE}/worker_vm/?name=${name}" | split_response "${tmpdir}/worker-lookup.json")"
  [[ "$status" == "200" ]] || err "worker_vm GET failed ($(fmt_status "$status")): $(cat "${tmpdir}/worker-lookup.json")"

  existing_id="$(jq -r --arg name "$name" \
    '.objects[] | select(.name == $name) | .id // empty' \
    "${tmpdir}/worker-lookup.json" | head -1)"

  if [[ -n "$existing_id" ]]; then
    # Pexip's API doesn't expose a "give me back the bootstrap blob for an
    # existing worker_vm" endpoint - the blob only comes from the original
    # POST response and isn't stored anywhere we can fetch it from later.
    #
    # So when we find a leftover worker_vm record (e.g. from a previous
    # apply that failed partway through, like an ACME error after this
    # step succeeded), we DELETE it and POST fresh. Safe because the
    # matching GCE VM is also being recreated by terraform on this apply,
    # so there's no running node with state we'd be wiping.
    echo "    already registered (id=${existing_id}); deleting + recreating to get a fresh bootstrap blob..." >&2
    status="$(pexip_curl -X DELETE \
      "${API_BASE}/worker_vm/${existing_id}/" | split_response "${tmpdir}/worker-delete.json")"
    case "$status" in
      200|202|204)
        echo "    deleted worker_vm id=${existing_id}" >&2
        ;;
      *)
        err "worker_vm DELETE (id=${existing_id}) failed ($(fmt_status "$status")): $(cat "${tmpdir}/worker-delete.json"). Run ./scripts/nuke.sh && ./scripts/setup.sh to start clean."
        ;;
    esac
    # Fall through to the POST branch below by clearing existing_id.
    existing_id=""
  fi

  if [[ -z "$existing_id" ]]; then
    # Build the POST payload from the node JSON + the system_location URI we
    # just resolved. Pexip's worker_vm API expects system_location as a URI,
    # not a name or id.
    payload="$(jq -nc \
      --argjson n "$node_json" \
      --arg sysloc "$sysloc_uri" \
      '{
        name:                        $n.name,
        hostname:                    $n.hostname,
        domain:                      $n.domain,
        address:                     $n.address,
        netmask:                     $n.netmask,
        gateway:                     $n.gateway,
        password:                    $n.password_hash,
        node_type:                   "CONFERENCING",
        system_location:             $sysloc,
        deployment_type:             "MANUAL-PROVISION-ONLY",
        enable_distributed_database: true,
        ssh_authorized_keys_use_cloud: true
      } + (if $n.static_nat_address != null and $n.static_nat_address != "" then {static_nat_address: $n.static_nat_address} else {} end)')"

    status="$(pexip_curl -X POST \
      -H 'Content-Type: application/json' \
      --data "$payload" \
      "${API_BASE}/worker_vm/" | split_response "${tmpdir}/worker-create.json")"

    case "$status" in
      201|200)
        # The POST response body IS the bootstrap config blob - exactly what
        # the GCE conferencing_node_config metadata key expects.
        config_b64="$(base64 -w0 < "${tmpdir}/worker-create.json" 2>/dev/null || base64 < "${tmpdir}/worker-create.json" | tr -d '\n')"
        ;;
      *)
        err "worker_vm POST failed ($(fmt_status "$status")): $(cat "${tmpdir}/worker-create.json")"
        ;;
    esac
  fi

  configs_array="$(jq -c --arg b64 "$config_b64" '. + [$b64]' <<<"$configs_array")"
done < <(jq -c '.[]' <<<"$PEXIP_CONF_NODES_JSON")

# ----------------------------------------------------------------------------
# 3. Emit the configs to a file terraform's data.local_file can read.
# ----------------------------------------------------------------------------
mkdir -p "$PEXIP_OUT_DIR"
out_file="${PEXIP_OUT_DIR}/conf-configs.json"
jq -nc --argjson c "$configs_array" '{configs: $c}' > "$out_file"
echo "==> Wrote ${out_file}" >&2
cat "$out_file"
