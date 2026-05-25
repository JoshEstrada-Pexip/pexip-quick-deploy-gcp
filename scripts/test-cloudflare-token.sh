#!/usr/bin/env bash
# ============================================================================
# test-cloudflare-token.sh - validate a Cloudflare API token before we let
# Terraform burn 5 minutes of ACME issuance on a broken token.
#
# Replicates exactly what lego (inside vancluever/acme) will do:
#   1. Verify the token is valid at all
#   2. Look up the zone for the given domain (the call that 6111'd on us)
#   3. Create + delete a TXT record on that zone (DNS-01 challenge in
#      miniature)
#
# Inputs (env vars OR positional args):
#   CF_DNS_API_TOKEN  - the token (also accepted as $1)
#   ACME_DOMAIN       - the domain whose zone we'll touch (also $2)
#
# Exit codes:
#   0  all three checks passed - safe to proceed with ACME
#   1  bad inputs
#   2  token invalid / wrong format (the '6111' class of errors)
#   3  token valid but no Zone.DNS:Edit on the requested zone
#   4  zone lookup or record write failed for some other reason
# ============================================================================
set -euo pipefail

token="${CF_DNS_API_TOKEN:-${1:-}}"
domain="${ACME_DOMAIN:-${2:-}}"

if [[ -z "$token" ]]; then
  echo "Usage: $0 <cloudflare-api-token> <domain>" >&2
  echo "   or: CF_DNS_API_TOKEN=... ACME_DOMAIN=... $0" >&2
  exit 1
fi
if [[ -z "$domain" ]]; then
  echo "ERROR: domain is required (second arg or ACME_DOMAIN env var)" >&2
  exit 1
fi

# Strip whitespace - this is the same fix terraform's trimspace() applies.
# read -s on some terminals leaves a trailing newline that Cloudflare
# rejects with "6111: Invalid format for Authorization header".
token="$(printf '%s' "$token" | tr -d '[:space:]')"

CF_API="https://api.cloudflare.com/client/v4"
ok()   { printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
fail() { printf "  \033[31mFAIL\033[0m  %s\n" "$*" >&2; }

fmt_status() {
  local s="$1"
  if [[ "$s" == "000" || "$s" == "0" || -z "$s" ]]; then
    echo "Connection Failed (network offline or API host unreachable)"
  else
    echo "HTTP $s"
  fi
}

# Tiny curl wrapper that captures body + status separately. We don't use
# --fail because we want to read 4xx bodies ourselves (Cloudflare's error
# codes live in the JSON body, not the HTTP status).
cf_get() {
  curl --silent --show-error \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    --write-out '\n%{http_code}\n' \
    "$@"
}

# Pull the first .errors[].code from a Cloudflare response body (which is
# always on the second-to-last line after our --write-out trick).
cf_error_code() {
  local body="$1"
  echo "$body" | jq -r '.errors[0].code // empty' 2>/dev/null
}

# Run a curl command and split body / status. Echoes "STATUS|BODY" to stdout.
cf_call() {
  local raw status body
  raw="$(cf_get "$@")"
  status="${raw##*$'\n'}"
  body="${raw%$'\n'*}"
  echo "${status}|${body}"
}

# ----------------------------------------------------------------------------
# Test 1: token is valid at all
# ----------------------------------------------------------------------------
echo "==> Cloudflare token preflight"
result="$(cf_call "${CF_API}/user/tokens/verify")"
status="${result%%|*}"
body="${result#*|}"

if [[ "$status" != "200" ]]; then
  err_code="$(cf_error_code "$body")"
  fail "token verify failed ($(fmt_status "$status"), Cloudflare code ${err_code:-none})"
  case "$err_code" in
    6003|6111)
      echo "    -> Token format is invalid. Likely causes:" >&2
      echo "       - You pasted a Global API Key instead of an API Token." >&2
      echo "       - The token has stray whitespace. Re-copy from Cloudflare." >&2
      echo "       - The token was revoked." >&2
      ;;
    1000)
      echo "    -> Token is unauthenticated. Probably revoked or never valid." >&2
      ;;
    *)
      echo "    -> Body: $body" >&2
      ;;
  esac
  exit 2
fi

token_status="$(echo "$body" | jq -r '.result.status // "unknown"')"
if [[ "$token_status" != "active" ]]; then
  fail "token verify returned status '$token_status' (expected 'active')"
  exit 2
fi
ok "token is valid and active"

# ----------------------------------------------------------------------------
# Test 2: zone lookup works for the requested domain
#
# Cloudflare zones are at the apex (example.com), not the subdomain. If the
# user passes "demo.example.com" we trim to "example.com". This matches what
# lego does internally.
# ----------------------------------------------------------------------------
# Split on dots; if more than 2 parts, take the last 2. (Doesn't handle
# multi-part TLDs like .co.uk perfectly - lego doesn't either; users with
# those need to set ACME_DOMAIN to the apex directly.)
zone_apex="$domain"
dot_count="$(echo "$domain" | tr -cd '.' | wc -c | tr -d ' ')"
if [[ "$dot_count" -ge 2 ]]; then
  zone_apex="$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')"
fi

result="$(cf_call "${CF_API}/zones?name=${zone_apex}")"
status="${result%%|*}"
body="${result#*|}"

if [[ "$status" != "200" ]]; then
  fail "zone lookup failed ($(fmt_status "$status"))"
  echo "    -> Body: $body" >&2
  exit 4
fi

zone_count="$(echo "$body" | jq -r '.result_info.count // 0')"
if [[ "$zone_count" == "0" ]]; then
  fail "no Cloudflare zone matching '${zone_apex}'"
  echo "    -> Either:" >&2
  echo "       - The domain isn't actually on Cloudflare" >&2
  echo "       - The token's zone scope doesn't include this zone" >&2
  echo "       - You meant a different apex (got '${zone_apex}' from '${domain}')" >&2
  exit 3
fi

zone_id="$(echo "$body" | jq -r '.result[0].id')"
ok "found zone '${zone_apex}' (id: ${zone_id})"

# ----------------------------------------------------------------------------
# Test 3: can we create + delete a TXT record? This is the actual DNS-01
# capability we'll need.
# ----------------------------------------------------------------------------
test_name="_acme-preflight-$(date +%s).${zone_apex}"
test_payload="$(jq -nc \
  --arg name "$test_name" \
  --arg content "pexip-quick-deploy preflight test - safe to delete" \
  '{type:"TXT", name:$name, content:$content, ttl:120}')"

result="$(cf_call -X POST \
  --data "$test_payload" \
  "${CF_API}/zones/${zone_id}/dns_records")"
status="${result%%|*}"
body="${result#*|}"

if [[ "$status" != "200" ]]; then
  err_code="$(cf_error_code "$body")"
  fail "TXT record create failed ($(fmt_status "$status"), Cloudflare code ${err_code:-none})"
  case "$err_code" in
    9109|10000|1000)
      echo "    -> Token doesn't have Zone.DNS:Edit on this zone (or the zone is in a different account)." >&2
      echo "       Please re-create or edit the token at https://dash.cloudflare.com/profile/api-tokens" >&2
      echo "       with permission: Zone -> DNS -> Edit, scoped to include '${zone_apex}'." >&2
      if [[ "$err_code" == "1000" ]]; then
        echo "       (Cloudflare returned code 1000 'There was an unknown error' which often maps to permission scope issues.)" >&2
      fi
      ;;
    *)
      echo "    -> Body: $body" >&2
      ;;
  esac
  exit 3
fi

record_id="$(echo "$body" | jq -r '.result.id')"
ok "TXT record created (id: ${record_id})"

# Clean up immediately - we don't want preflight artifacts hanging around.
result="$(cf_call -X DELETE "${CF_API}/zones/${zone_id}/dns_records/${record_id}")"
status="${result%%|*}"
if [[ "$status" != "200" ]]; then
  fail "TXT record delete failed ($(fmt_status "$status")) - manual cleanup needed"
  echo "    -> Record ID ${record_id} on zone ${zone_id}" >&2
  exit 4
fi
ok "TXT record deleted (cleanup complete)"

echo
echo "Cloudflare token is ready for ACME DNS-01. Safe to proceed."
exit 0
