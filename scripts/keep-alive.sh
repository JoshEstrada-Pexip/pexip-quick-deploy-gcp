#!/usr/bin/env bash
# ============================================================================
# keep-alive.sh - defeat the Cloud Shell idle timeout during a long deploy
#
# Cloud Shell disconnects sessions that are "idle" for ~20 minutes, and our
# terraform apply takes 8-12 minutes. The window is tight - if the user
# walks away or runs setup.sh in a tab they're not actively watching, the
# session can time out mid-apply and leave the GCP project with half-
# created resources and an incomplete state file.
#
# This script defeats the timeout by emitting a small status line every
# 4 minutes (well under the 20-min threshold). Cloud Shell counts any
# terminal output as activity.
#
# USAGE
# -----
# Run this in a SEPARATE Cloud Shell tab from the one running setup.sh
# (so its output doesn't interfere with terraform's). It'll loop until
# you Ctrl-C or close the tab.
#
#   ./scripts/keep-alive.sh
#
# Or run it in the background of the same tab if you don't mind the
# occasional status line in your output:
#
#   ./scripts/keep-alive.sh &
#   # ... when done:
#   kill %1
# ============================================================================
set -euo pipefail

INTERVAL_SECONDS="${KEEP_ALIVE_INTERVAL:-240}" # 4 min default

# Detect that we're actually in Cloud Shell. If not, this script is
# pointless - other shells don't have the same idle timeout. Warn and
# exit so users on local terminals don't leave a useless process running.
if [[ "${CLOUD_SHELL:-}" != "true" && -z "${DEVSHELL_PROJECT_ID:-}" ]]; then
  cat <<'EOF' >&2
keep-alive.sh: not running inside Cloud Shell.

This script exists to defeat Cloud Shell's idle-session timeout. On a
local terminal there's no timeout to defeat, so running this just
prints status lines forever for no reason. Exiting.

If you really want to run it anyway, set FORCE_KEEP_ALIVE=1.
EOF
  [[ "${FORCE_KEEP_ALIVE:-}" == "1" ]] || exit 1
fi

trap 'echo; echo "keep-alive stopped."; exit 0' INT TERM

echo "keep-alive started. Pinging every ${INTERVAL_SECONDS}s to defeat Cloud Shell idle timeout."
echo "Leave this tab open while terraform apply runs. Ctrl-C to stop."
echo

count=0
while true; do
  count=$((count + 1))
  # ISO-8601 timestamp keeps log scrubbing easy and is visibly "active".
  echo "[$(date -u +%H:%M:%SZ)] keep-alive ping #${count}"
  sleep "$INTERVAL_SECONDS"
done
