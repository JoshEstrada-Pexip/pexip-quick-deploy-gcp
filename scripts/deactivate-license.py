#!/usr/bin/env python3
"""
Pexip Infinity Pre-Destroy License Return/Deactivation Tool
Checks if active licenses exist on the Management Node and returns them via DELETE requests.
"""

import sys
import os
import argparse
import json
import socket
import re
import subprocess
import urllib3

# Suppress urllib3 SSL warnings for self-signed certificates
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

try:
    import requests
except ImportError:
    print("\033[91mError: Required Python package 'requests' is not installed.\033[0m")
    sys.exit(1)

# ANSI escape codes for coloring terminal output
COLOR_GREEN = "\033[92m"
COLOR_YELLOW = "\033[93m"
COLOR_RED = "\033[91m"
COLOR_CYAN = "\033[96m"
COLOR_RESET = "\033[0m"


def print_success(msg):
    print(f"{COLOR_GREEN}[SUCCESS] {msg}{COLOR_RESET}")


def print_info(msg):
    print(f"{COLOR_CYAN}[INFO] {msg}{COLOR_RESET}")


def print_warn(msg):
    print(f"{COLOR_YELLOW}[WARNING] {msg}{COLOR_RESET}")


def print_error(msg):
    print(f"{COLOR_RED}[ERROR] {msg}{COLOR_RESET}", file=sys.stderr)


def get_terraform_outputs(terraform_dir):
    """Run terraform output -json to get the management IP."""
    try:
        # Run terraform output -json in the specified terraform directory
        res = subprocess.run(
            ["terraform", "output", "-json"],
            cwd=terraform_dir,
            capture_output=True,
            text=True,
            timeout=10,
        )
        if res.returncode == 0 and res.stdout.strip():
            return json.loads(res.stdout)
    except Exception as e:
        print_warn(f"Could not read Terraform output: {e}")
    return {}


def parse_password_from_tfvars(tfvars_path):
    """Parse pexip_admin_password from terraform.tfvars directly."""
    if not os.path.exists(tfvars_path):
        return None
    try:
        with open(tfvars_path, "r") as f:
            for line in f:
                # Look for pexip_admin_password variable assignment
                match = re.match(
                    r'^\s*pexip_admin_password\s*=\s*["\'](.*?)["\']\s*$', line
                )
                if match:
                    return match.group(1)
    except Exception as e:
        print_warn(f"Failed to read/parse {tfvars_path}: {e}")
    return None


def is_port_open(ip, port, timeout=2):
    """Check if the target port is open with a short timeout."""
    try:
        with socket.create_connection((ip, port), timeout=timeout):
            return True
    except (socket.timeout, ConnectionRefusedError, OSError):
        return False


def main():
    parser = argparse.ArgumentParser(description="Pexip License Deactivation Tool")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument(
        "--check",
        action="store_true",
        help="Check if licenses are active (exit code 10 if active)",
    )
    group.add_argument(
        "--deactivate",
        action="store_true",
        help="Deactivate and return all active licenses",
    )

    parser.add_argument("--host", help="Pexip Management Node IP address or FQDN")
    parser.add_argument("--password", help="Pexip admin UI password")
    parser.add_argument(
        "--verify-ssl", action="store_true", help="Verify HTTPS SSL certificate"
    )

    args = parser.parse_args()

    host = args.host
    password = args.password

    # If host or password are not provided, try to discover them from Terraform configs
    # We check:
    # 1. Current directory
    # 2. 'terraform' subdirectory
    # 3. Parent directory (if run from a subfolder)
    search_dirs = [
        os.getcwd(),
        os.path.join(os.getcwd(), "terraform"),
        os.path.dirname(os.getcwd()),
    ]

    tfvars_path = None
    tf_dir = None

    for d in search_dirs:
        candidate_tfvars = os.path.join(d, "terraform.tfvars")
        if os.path.exists(candidate_tfvars):
            tfvars_path = candidate_tfvars
            tf_dir = d
            break

    # Discover host IP/FQDN if not provided
    if not host and tf_dir:
        tf_outputs = get_terraform_outputs(tf_dir)
        admin_url = tf_outputs.get("management_admin_url", {}).get("value")
        if admin_url:
            # Extract host (FQDN or IP) from URL
            host = re.sub(r"^[^/]*//", "", admin_url).split("/")[0].split(":")[0]
        else:
            host = tf_outputs.get("management_public_ip", {}).get("value")

    # Discover password if not provided
    if not password and tfvars_path:
        password = parse_password_from_tfvars(tfvars_path)

    # If we couldn't find the host IP, we can't check/deactivate.
    # This is normal if the VM was never deployed or state was already cleaned.
    if not host:
        print_info(
            "No Pexip Management Node IP address found in Terraform state. Nothing to check."
        )
        sys.exit(0)

    if not password:
        print_error(
            "Pexip admin password could not be discovered. Please specify --password."
        )
        sys.exit(1)

    # Check if a custom port is specified in host
    check_port = 443
    check_host = host
    if ":" in host:
        parts = host.split(":")
        check_host = parts[0]
        try:
            check_port = int(parts[1])
        except ValueError:
            pass

    # Preflight check: Is port open?
    # If the VM is stopped, offline, or deleted, we should exit successfully.
    print_info(
        f"Checking if Management Node at {check_host}:{check_port} is reachable..."
    )
    if not is_port_open(check_host, check_port, timeout=2):
        print_info(
            f"Pexip Management Node port {check_port} is unreachable (offline or already deleted). Skipping license check."
        )
        sys.exit(0)

    # Initialize connection
    base_url = f"https://{host}/api/admin/configuration/v1"
    session = requests.Session()
    session.auth = ("admin", password)
    session.headers.update(
        {"Content-Type": "application/json", "Accept": "application/json"}
    )

    # Fetch active licenses
    print_info("Fetching active licenses from Management Node...")
    url = f"{base_url}/licence/"
    try:
        res = session.get(url, verify=args.verify_ssl, timeout=10)
        if res.status_code != 200:
            print_error(f"Failed to query licenses: API returned {res.status_code}")
            sys.exit(1)

        data = res.json()
        licenses = data.get("objects", [])

        if not licenses:
            print_info("No active licenses found on the Management Node.")
            sys.exit(0)

        print_warn(f"Found {len(licenses)} active license(s) on the Management Node:")
        for lic in licenses:
            entitlement = lic.get("entitlement_id", "Unknown")
            description = lic.get("description", "No description")
            print_warn(f"  - Key: {entitlement} ({description})")

        if args.check:
            # Active licenses exist. Exit with code 10 to notify calling shell script.
            sys.exit(10)

        if args.deactivate:
            print_info("Initiating license deactivation/return requests...")
            success = True

            # Group licenses by entitlement_id to only return one per unique entitlement
            unique_entitlements = {}
            for lic in licenses:
                entitlement = lic.get("entitlement_id")
                if entitlement and entitlement not in unique_entitlements:
                    unique_entitlements[entitlement] = lic

            for entitlement, lic in unique_entitlements.items():
                resource_uri = lic.get("resource_uri")
                if not resource_uri:
                    continue

                # construct delete URL
                delete_url = f"https://{host}{resource_uri}"
                print_info(
                    f"Returning license entitlement {entitlement} via DELETE {resource_uri}..."
                )

                del_res = session.delete(delete_url, verify=args.verify_ssl, timeout=15)
                if del_res.status_code in (200, 204):
                    print_success(
                        f"Successfully returned license entitlement {entitlement}."
                    )
                else:
                    print_error(
                        f"Failed to return license entitlement {entitlement}: HTTP {del_res.status_code}"
                    )
                    try:
                        print_error(f"Response: {del_res.json()}")
                    except Exception:
                        print_error(f"Response: {del_res.text}")
                    success = False

            if not success:
                print_error("One or more license returns failed.")
                sys.exit(1)

            print_success("All licenses returned successfully.")
            sys.exit(0)

    except requests.exceptions.SSLError as e:
        print_error(f"SSL verification failed connecting to https://{host}. Error: {e}")
        sys.exit(1)
    except requests.exceptions.ConnectionError as e:
        print_error(
            f"Failed to connect to Pexip Management Node at https://{host}. Error: {e}"
        )
        sys.exit(1)
    except Exception as e:
        print_error(f"An unexpected error occurred: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
