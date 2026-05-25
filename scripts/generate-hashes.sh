#!/usr/bin/env bash
# ============================================================================
# generate-hashes.sh — produce Pexip-compatible password hashes
#
# Replaces what the Pexip terraform provider's pexip_infinity_ssh_password_hash
# and pexip_infinity_web_password_hash resources did, but as a one-shot script
# so terraform doesn't keep those values in state (where they cause destroy-
# time fragility because the provider tries to refresh them via the Manager
# API even though they're pure-local computations).
#
# Both algorithms reproduced exactly from the Pexip provider source:
#   github.com/pexip/terraform-provider-infinity/internal/helpers/hash.go
#
# Web hash:  pbkdf2_sha256$36000$<12-char alnum salt>$<base64 sha256 hash>
# SSH hash:  $6$rounds=5000$<16-char alnum salt>$<sha512-crypt hash>
#
# Input:  reads the plaintext password from stdin (so it never lands on the
#         command line / process list).
# Output: JSON object with both hashes on stdout, suitable for use with
#         terraform's `data "external"` source.
# ============================================================================
set -euo pipefail

# We hand python the script as $0 and let it read the password from stdin.
# This avoids the trap of `exec python3 - <<EOF` which would replace the
# password stdin with the heredoc body.
python3 -W ignore::DeprecationWarning -c '
try:
    import crypt
except ImportError:
    crypt = None
import hashlib
import base64
import secrets
import string
import sys
import json
import subprocess

ALNUM = string.ascii_letters + string.digits

def alnum_salt(length):
    # secrets.choice uses crypto-secure RNG, matching the Go provider source
    # which uses crypto/rand-based GenerateRandomAlphanumeric.
    return "".join(secrets.choice(ALNUM) for _ in range(length))

def django_pbkdf2_sha256(password):
    # Provider source: salt=12 chars, rounds=36000, sha256, base64-std.
    salt = alnum_salt(12)
    rounds = 36000
    hashed = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), rounds)
    return "pbkdf2_sha256${0}${1}${2}".format(rounds, salt, base64.b64encode(hashed).decode("ascii"))

def sha512_crypt(password):
    # Provider source: salt=16 chars, rounds=5000, libcrypt sha512_crypt.
    # python crypt wraps libcrypt; on Linux (incl. Cloud Shell) it produces a
    # Pexip-compatible $6$rounds=5000$...$ hash. On macOS, libcrypt does NOT
    # support sha512_crypt and silently falls back to DES, producing a
    # truncated 13-char hash like $6xxxxxxxxxxxx that the Manager will
    # silently reject. Detect that and fall back to passlib or openssl.
    salt = alnum_salt(16)
    
    # 1. Try python built-in crypt (only on Linux where it supports sha512)
    if crypt is not None and hasattr(crypt, "crypt"):
        config = "$6$rounds=5000${0}$".format(salt)
        h = crypt.crypt(password, config)
        if h is not None and h.startswith("$6$") and len(h) >= 80:
            return h

    # 2. Try passlib if installed
    try:
        from passlib.hash import sha512_crypt as passlib_sha512
        return passlib_sha512.hash(password, rounds=5000, salt=salt)
    except ImportError:
        pass

    # 3. Try openssl (pre-installed on macOS and standard Linux hosts)
    try:
        res = subprocess.run(
            ["openssl", "passwd", "-6", "-stdin", "-salt", salt],
            input=password.encode("utf-8") + b"\n",
            capture_output=True,
            check=True
        )
        h = res.stdout.decode("utf-8").strip()
        if h.startswith("$6$") and len(h) >= 80:
            return h
    except Exception:
        pass

    raise RuntimeError(
        "Could not generate a valid sha512-crypt hash. "
        "Built-in Python crypt, passlib, and openssl all failed or are unavailable. "
        "Please run this on Linux/Cloud Shell, or install passlib (pip install passlib)."
    )

raw = sys.stdin.read().strip()
# terraform data.external passes input as JSON; direct callers pass plain text.
if raw.startswith("{") and raw.endswith("}"):
    try:
        parsed = json.loads(raw)
        if "password" in parsed:
            raw = parsed["password"]
    except json.JSONDecodeError:
        pass

if len(raw) < 8:
    print("password must be at least 8 characters", file=sys.stderr)
    sys.exit(1)

json.dump({
    "web_hash": django_pbkdf2_sha256(raw),
    "ssh_hash": sha512_crypt(raw),
}, sys.stdout)
'
