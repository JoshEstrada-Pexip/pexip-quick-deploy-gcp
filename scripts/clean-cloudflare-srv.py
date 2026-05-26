#!/usr/bin/env python3
import os
import sys
import re
import urllib.request
import urllib.error
import json


def parse_tfvars(tfvars_path):
    config = {}
    if not os.path.exists(tfvars_path):
        return config
    with open(tfvars_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            match = re.match(r"^([a-zA-Z0-9_]+)\s*=\s*(.*)$", line)
            if match:
                key = match.group(1)
                val = match.group(2).strip().strip('"').strip("'")
                config[key] = val
    return config


def cf_api_request(url, token, method="GET", data=None):
    req = urllib.request.Request(url, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")

    body = None
    if data is not None:
        body = json.dumps(data).encode("utf-8")

    try:
        with urllib.request.urlopen(req, data=body) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8")
        try:
            err_json = json.loads(err_body)
            print(f"Cloudflare API Error ({e.code}): {json.dumps(err_json, indent=2)}")
        except Exception:
            print(f"Cloudflare HTTP Error ({e.code}): {err_body}")
        sys.exit(1)
    except Exception as e:
        print(f"Request failed: {e}")
        sys.exit(1)


def main():
    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    tfvars_path = os.path.join(repo_root, "terraform", "terraform.tfvars")

    config = {}
    if os.path.exists(tfvars_path):
        config = parse_tfvars(tfvars_path)

    token = os.environ.get("CF_DNS_API_TOKEN") or config.get("cloudflare_api_token")
    domain = os.environ.get("ACME_DOMAIN") or config.get("acme_domain")
    zone_name = (
        os.environ.get("ACME_ZONE_NAME") or config.get("cloudflare_zone_name") or domain
    )

    if not token:
        print(
            "Error: Cloudflare API token is empty or not provided via CF_DNS_API_TOKEN / terraform.tfvars"
        )
        sys.exit(1)
    if not domain:
        print(
            "Error: ACME domain is empty or not provided via ACME_DOMAIN / terraform.tfvars"
        )
        sys.exit(1)

    print(
        f"Cloudflare API Token found. Target domain: {domain}, Zone name: {zone_name}"
    )

    # 1. Retrieve Zone ID
    print("Retrieving zone ID from Cloudflare...")
    zone_url = f"https://api.cloudflare.com/client/v4/zones?name={zone_name}"
    zone_res = cf_api_request(zone_url, token)

    if not zone_res.get("success") or not zone_res.get("result"):
        print(f"Error: Failed to find zone '{zone_name}' on Cloudflare.")
        sys.exit(1)

    zone_id = zone_res["result"][0]["id"]
    print(f"Found Zone ID: {zone_id}")

    # 2. Retrieve DNS records
    print("Listing DNS records in zone...")
    records_url = (
        f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records?per_page=100"
    )
    records_res = cf_api_request(records_url, token)

    if not records_res.get("success"):
        print("Error: Failed to list DNS records.")
        sys.exit(1)

    records = records_res.get("result", [])

    # Parse hostnames
    manager_host = (
        os.environ.get("ACME_MANAGER_HOSTNAME")
        or config.get("acme_manager_hostname")
        or "pexip-mgr"
    )
    conf_prefix = (
        os.environ.get("ACME_CONF_HOSTNAME_PREFIX")
        or config.get("acme_conf_hostname_prefix")
        or "pexip-conf"
    )

    # Define exact matching names for SRV records
    srv_names = {
        f"_sip._tcp.{domain}",
        f"_sips._tcp.{domain}",
        f"_pexapp._tcp.{domain}",
    }

    # Define patterns for A and TXT records matching our deployment names
    domain_esc = re.escape(domain)
    manager_esc = re.escape(manager_host)
    conf_prefix_esc = re.escape(conf_prefix)

    patterns = [
        # Manager A record (e.g. pexip-mgr.example.com)
        re.compile(rf"^{manager_esc}\.{domain_esc}$", re.IGNORECASE),
        # Conferencing Nodes A records (e.g. pexip-conf-1.example.com)
        re.compile(rf"^{conf_prefix_esc}-\d+\.{domain_esc}$", re.IGNORECASE),
        # Let's Encrypt challenge TXT records
        re.compile(rf"^_acme-challenge\.{domain_esc}$", re.IGNORECASE),
        re.compile(rf"^_acme-challenge\.{manager_esc}\.{domain_esc}$", re.IGNORECASE),
        re.compile(
            rf"^_acme-challenge\.{conf_prefix_esc}-\d+\.{domain_esc}$", re.IGNORECASE
        ),
        # Preflight test TXT records
        re.compile(rf"^_acme-preflight-\d+\.{domain_esc}$", re.IGNORECASE),
    ]

    to_delete = []
    for r in records:
        name = r.get("name", "")
        rtype = r.get("type", "")

        # Match SRV records by name
        if rtype == "SRV" and name in srv_names:
            to_delete.append(r)
        # Match A or TXT records by naming patterns
        elif rtype in ("A", "TXT") and any(pat.match(name) for pat in patterns):
            to_delete.append(r)

    is_check = "--check" in sys.argv

    if not to_delete:
        if is_check:
            print("No conflicting Pexip DNS records found in Cloudflare.")
            sys.exit(0)
        else:
            print(
                "No conflicting or orphaned Pexip DNS records found in Cloudflare. You are good to go!"
            )
            return

    if is_check:
        print("Found conflicting Pexip DNS records on Cloudflare:")
        for r in to_delete:
            content = r.get("content", "")
            if r.get("type") == "SRV":
                srv_data = r.get("data", {})
                content = f"priority={srv_data.get('priority')}, target={srv_data.get('target')}"
            print(f"  - [{r['type']}] {r['name']} -> {content}")
        sys.exit(2)

    print(f"Found {len(to_delete)} matching Pexip DNS record(s) to delete:")
    for r in to_delete:
        print(f"  - [{r['type']}] {r['name']} (ID: {r['id']})")

    # 3. Delete DNS records
    for r in to_delete:
        print(f"Deleting record {r['name']} ({r['type']})...")
        del_url = f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records/{r['id']}"
        del_res = cf_api_request(del_url, token, method="DELETE")
        if del_res.get("success"):
            print(f"  Successfully deleted {r['name']}.")
        else:
            print(f"  Failed to delete {r['name']}.")

    print("Cloudflare DNS cleanup completed successfully!")


if __name__ == "__main__":
    main()
