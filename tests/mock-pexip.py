#!/usr/bin/env python3
"""
mock-pexip.py - tiny HTTP server that mimics Pexip's Management API just
enough for install-cert.sh and register-conf-nodes.sh to exercise their
plumbing without a real Manager VM.

This is NOT a full Pexip simulator. It exists so we can iterate on the
shell scripts' request shapes (URI construction, basic-auth handling,
PEM concatenation, idempotency on re-run) in ~1s instead of waiting 10
minutes for a real VM. The scripts' field-name guesses for the cert
upload payload are UNVERIFIED (see memory/reference-pexip-api.md); a
green test here means the plumbing works against what we THINK the
schema is. It does NOT prove the schema is right.

Usage:
    python3 mock-pexip.py --port 8443 --recordings-dir /tmp/recordings

Writes every request as a JSON line to <recordings-dir>/requests.jsonl:
    {"method": "POST", "path": "/api/admin/.../", "body": "...", "auth": "admin:x"}

Pre-seeds a few fixtures so the scripts can complete a full happy-path:
  - GET /api/admin/configuration/v1/worker_vm/?name=pexip-conf-1
      -> empty (caller will POST a new one)
  - GET /api/admin/configuration/v1/managementvm/?name=pexip-mgr
      -> one entry at resource_uri /api/admin/configuration/v1/managementvm/1/
  - GET /api/admin/configuration/v1/tls_certificate/
      -> empty list (caller will POST a new one)
  - POST /api/admin/configuration/v1/tls_certificate/ -> 201 + body with id 1
  - PATCH /api/admin/configuration/v1/{worker_vm,managementvm}/{id}/ -> 200
"""

import argparse
import base64
import json
import os
import ssl
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs


# --- in-memory state (reset on each server start) ----------------------------

# These are pre-seeded so the scripts can complete a happy-path run. The
# test harness can override before starting the server by writing a JSON
# blob to MOCK_STATE_FILE; see tests/test-install-cert.sh.
STATE = {
    "management_vm": [
        {
            "id": 1,
            "name": "pexip-mgr",
            "resource_uri": "/api/admin/configuration/v1/management_vm/1/",
            "tls_certificate": None,
            "alternative_fqdn": "",
        }
    ],
    "worker_vm": [
        # Seeded by the test harness if needed - default empty, so the
        # script falls into the POST-fresh branch.
    ],
    "tls_certificate": [],
    "dns_server": [],
    "ntp_server": [],
    "system_location": [
        {
            "id": 1,
            "name": "Primary Location",
            "resource_uri": "/api/admin/configuration/v1/system_location/1/"
        }
    ],
    "licence": [],
    "conference": [],
    "gateway_routing_rule": [],
    "end_user": [],
    "device": [],
    # next-id counter per resource type
    "_next_id": {
        "tls_certificate": 1,
        "worker_vm": 1,
        "dns_server": 1,
        "ntp_server": 1,
        "system_location": 2,
        "licence": 1,
        "conference": 1,
        "gateway_routing_rule": 1,
        "end_user": 1,
        "device": 1,
    },
}


def next_id(kind):
    n = STATE["_next_id"][kind]
    STATE["_next_id"][kind] = n + 1
    return n


# --- request recorder -------------------------------------------------------

RECORDINGS_PATH = None


def record(method, path, body, auth_header):
    if RECORDINGS_PATH is None:
        return
    entry = {
        "method": method,
        "path": path,
        "body": body if body else None,
        "auth": auth_header,
    }
    with open(RECORDINGS_PATH, "a") as f:
        f.write(json.dumps(entry) + "\n")


# --- handlers ---------------------------------------------------------------

API_PREFIX = "/api/admin/configuration/v1"
COMMAND_PREFIX = "/api/admin/command/v1"


def parse_subject_cn_from_pem(pem):
    """Extract the Common Name from a PEM cert's subject line using openssl.
    Output formats we've seen across openssl/libressl versions:
      subject=CN=foo.example.com           (macOS LibreSSL)
      subject= /CN=foo.example.com         (older OpenSSL)
      subject=CN = foo.example.com         (newer OpenSSL with RFC2253 setting)
    Use a regex that handles all three. Returns None if openssl missing
    or parsing failed - the mock falls back to a placeholder."""
    import re
    import subprocess
    try:
        result = subprocess.run(
            ["openssl", "x509", "-noout", "-subject"],
            input=pem.encode("utf-8"),
            capture_output=True,
            timeout=2,
        )
        if result.returncode != 0:
            return None
        line = result.stdout.decode("utf-8", "replace").strip()
        # CN= followed by optional spaces, then the value up to next , or /
        # or end of line. Case-insensitive.
        match = re.search(r"CN\s*=\s*([^,/]+)", line, re.IGNORECASE)
        if match:
            return match.group(1).strip()
    except (FileNotFoundError, subprocess.TimeoutExpired, Exception):
        pass
    return None


class Handler(BaseHTTPRequestHandler):
    # Quiet down the default access log so test output stays readable.
    def log_message(self, fmt, *args):
        if os.environ.get("MOCK_VERBOSE"):
            sys.stderr.write("[mock] " + (fmt % args) + "\n")

    # All endpoints require HTTP basic auth - install-cert.sh sends it on
    # every request and we want to assert that.
    def _check_auth(self):
        h = self.headers.get("Authorization", "")
        if not h.startswith("Basic "):
            self.send_response(401)
            self.end_headers()
            return None
        try:
            decoded = base64.b64decode(h[len("Basic "):]).decode("utf-8")
        except Exception:
            self.send_response(401)
            self.end_headers()
            return None
        if not decoded.startswith("admin:"):
            self.send_response(401)
            self.end_headers()
            return None
        return decoded  # "admin:password"

    def _read_body(self):
        n = int(self.headers.get("Content-Length", "0"))
        if n == 0:
            return ""
        return self.rfile.read(n).decode("utf-8")

    def _json(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _routes(self, method):
        """Find the endpoint kind ('tls_certificate', 'worker_vm', ...) and
        the trailing id (if any) from the URL. Returns (kind, item_id, query)."""
        parsed = urlparse(self.path)
        path = parsed.path
        query = {k: v[0] for k, v in parse_qs(parsed.query).items()}

        if not path.startswith(API_PREFIX + "/"):
            return None, None, query
        rest = path[len(API_PREFIX) + 1:].strip("/")
        parts = rest.split("/")
        if not parts:
            return None, None, query
        kind = parts[0]
        item_id = None
        if len(parts) >= 2 and parts[1]:
            try:
                item_id = int(parts[1])
            except ValueError:
                pass
        return kind, item_id, query

    def _is_command_certificates_import(self):
        """True if the current request path is the certificates_import endpoint.
        Match the path part only - ignore query string."""
        parsed = urlparse(self.path)
        return parsed.path.rstrip("/") == f"{COMMAND_PREFIX}/platform/certificates_import"

    # ---- GET ---------------------------------------------------------------
    def do_GET(self):
        auth = self._check_auth()
        if auth is None:
            return
        record("GET", self.path, "", auth)

        kind, item_id, query = self._routes("GET")
        if kind is None or kind not in STATE:
            return self._json(404, {"error_message": "unknown endpoint"})

        items = STATE[kind]

        # Filter by name, address, primary_email_address, alias, device_alias, or service_type if present.
        for filt in ("name", "address", "primary_email_address", "alias", "device_alias", "service_type"):
            if filt in query:
                items = [o for o in items if str(o.get(filt)) == str(query[filt])]

        return self._json(200, {
            "meta": {"total_count": len(items)},
            "objects": items,
        })

    # ---- POST --------------------------------------------------------------
    def do_POST(self):
        auth = self._check_auth()
        if auth is None:
            return
        body = self._read_body()
        record("POST", self.path, body, auth)

        # Special-case the command endpoint - it's a thing-doer that
        # parses the bundle and creates a tls_certificate record server-side.
        if self._is_command_certificates_import():
            try:
                payload = json.loads(body) if body else {}
            except json.JSONDecodeError:
                return self._json(400, {"error_message": "invalid JSON"})
            bundle = payload.get("bundle", "")
            if not bundle or "BEGIN CERTIFICATE" not in bundle:
                return self._json(400, {"error_message": "bundle must contain at least one CERTIFICATE"})
            if "BEGIN" not in bundle.replace("BEGIN CERTIFICATE", ""):
                return self._json(400, {"error_message": "bundle must contain a private key"})
            # Parse the leaf cert's CN to use as subject_name.
            # The bundle layout is: leaf, chain, key (concatenated).
            leaf_start = bundle.find("-----BEGIN CERTIFICATE-----")
            leaf_end = bundle.find("-----END CERTIFICATE-----", leaf_start)
            if leaf_start < 0 or leaf_end < 0:
                return self._json(400, {"error_message": "could not parse leaf certificate"})
            leaf_pem = bundle[leaf_start:leaf_end + len("-----END CERTIFICATE-----")]
            subject = parse_subject_cn_from_pem(leaf_pem) or f"imported-cert-{STATE['_next_id']['tls_certificate']}"

            new_id = next_id("tls_certificate")
            obj = {
                "id": new_id,
                "resource_uri": f"{API_PREFIX}/tls_certificate/{new_id}/",
                "subject_name": subject,
                "certificate": leaf_pem,
                # The mock doesn't store the key separately - the bundle stored above
                # contains it. Real Pexip stores them as separate fields internally.
            }
            STATE["tls_certificate"].append(obj)
            return self._json(200, {"status": "ok", "imported": [obj["resource_uri"]]})

        kind, _, _ = self._routes("POST")
        if kind is None or kind not in STATE:
            return self._json(404, {"error_message": "unknown endpoint"})

        try:
            payload = json.loads(body) if body else {}
        except json.JSONDecodeError:
            return self._json(400, {"error_message": "invalid JSON"})

        new_id = next_id(kind)
        obj = dict(payload)
        obj["id"] = new_id
        obj["resource_uri"] = f"{API_PREFIX}/{kind}/{new_id}/"

        # For worker_vm POST, Pexip's real API returns the bootstrap blob as
        # the body. We return a base64-encoded canned blob so the conf-node
        # registration script can decode it.
        if kind == "worker_vm":
            obj["bootstrap"] = base64.b64encode(b"mock-conf-bootstrap").decode("ascii")

        STATE[kind].append(obj)
        return self._json(201, obj)

    # ---- PATCH -------------------------------------------------------------
    def do_PATCH(self):
        auth = self._check_auth()
        if auth is None:
            return
        body = self._read_body()
        record("PATCH", self.path, body, auth)

        kind, item_id, _ = self._routes("PATCH")
        if kind is None or kind not in STATE or item_id is None:
            return self._json(404, {"error_message": "unknown endpoint or id"})

        try:
            patch = json.loads(body) if body else {}
        except json.JSONDecodeError:
            return self._json(400, {"error_message": "invalid JSON"})

        for o in STATE[kind]:
            if o["id"] == item_id:
                o.update(patch)
                return self._json(200, o)
        return self._json(404, {"error_message": "id not found"})

    # ---- DELETE ------------------------------------------------------------
    def do_DELETE(self):
        auth = self._check_auth()
        if auth is None:
            return
        record("DELETE", self.path, "", auth)

        kind, item_id, _ = self._routes("DELETE")
        if kind is None or kind not in STATE or item_id is None:
            return self._json(404, {"error_message": "unknown endpoint or id"})

        before = len(STATE[kind])
        STATE[kind] = [o for o in STATE[kind] if o["id"] != item_id]
        if len(STATE[kind]) == before:
            return self._json(404, {"error_message": "id not found"})
        self.send_response(204)
        self.end_headers()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8443)
    parser.add_argument("--recordings-dir", default="/tmp/mock-pexip")
    parser.add_argument("--state-file", default=None,
                        help="Optional JSON file to seed STATE from")
    parser.add_argument("--cert", default=None,
                        help="TLS cert PEM (for HTTPS). If omitted, runs HTTP.")
    parser.add_argument("--key", default=None, help="TLS key PEM (for HTTPS).")
    args = parser.parse_args()

    global RECORDINGS_PATH
    os.makedirs(args.recordings_dir, exist_ok=True)
    RECORDINGS_PATH = os.path.join(args.recordings_dir, "requests.jsonl")
    # Truncate on start so each test run gets a clean recording.
    open(RECORDINGS_PATH, "w").close()

    if args.state_file:
        with open(args.state_file) as f:
            seed = json.load(f)
        STATE.update(seed)

    server = HTTPServer(("127.0.0.1", args.port), Handler)

    if args.cert and args.key:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(args.cert, args.key)
        server.socket = ctx.wrap_socket(server.socket, server_side=True)
        scheme = "https"
    else:
        scheme = "http"

    sys.stderr.write(f"[mock] listening on {scheme}://127.0.0.1:{args.port}\n")
    sys.stderr.write(f"[mock] recording requests to {RECORDINGS_PATH}\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
