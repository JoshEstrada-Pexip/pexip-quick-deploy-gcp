#!/usr/bin/env python3
"""
Pexip Infinity TLS Certificate Cleanup Tool
Identifies and deletes unused certificates in the Pexip Management Node keystore.
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
        res = subprocess.run(
            ["terraform", "output", "-json"],
            cwd=terraform_dir,
            capture_output=True,
            text=True,
            timeout=10
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
                match = re.match(r'^\s*pexip_admin_password\s*=\s*["\'](.*?)["\']\s*$', line)
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


def get_cert_details(pem_string):
    """Extract details (Issuer, Expiration Date, Subject) from certificate PEM using openssl."""
    details = {"issuer": "Unknown", "expires": "Unknown", "subject": "Unknown"}
    if not pem_string:
        return details
    try:
        res = subprocess.run(
            ["openssl", "x509", "-noout", "-issuer", "-enddate", "-subject"],
            input=pem_string,
            capture_output=True,
            text=True,
            timeout=5
        )
        if res.returncode == 0:
            for line in res.stdout.splitlines():
                if line.startswith("issuer="):
                    details["issuer"] = line.replace("issuer=", "").strip()
                elif line.startswith("notAfter="):
                    details["expires"] = line.replace("notAfter=", "").strip()
                elif line.startswith("subject="):
                    details["subject"] = line.replace("subject=", "").strip()
    except Exception:
        pass
    return details


def main():
    parser = argparse.ArgumentParser(description="Pexip Certificate Cleanup Tool")
    parser.add_argument("--host", help="Pexip Management Node IP address or FQDN")
    parser.add_argument("--password", help="Pexip admin UI password")
    parser.add_argument("--verify-ssl", action="store_true", help="Verify HTTPS SSL certificate")
    parser.add_argument("--delete-all", action="store_true", help="Delete all unused certificates without prompting")
    
    args = parser.parse_args()

    host = args.host
    password = args.password

    # Discover host/password from Terraform configs
    search_dirs = [os.getcwd(), os.path.join(os.getcwd(), "terraform"), os.path.dirname(os.getcwd())]
    tfvars_path = None
    tf_dir = None
    
    for d in search_dirs:
        candidate_tfvars = os.path.join(d, "terraform.tfvars")
        if os.path.exists(candidate_tfvars):
            tfvars_path = candidate_tfvars
            tf_dir = d
            break

    if not host and tf_dir:
        tf_outputs = get_terraform_outputs(tf_dir)
        admin_url = tf_outputs.get("management_admin_url", {}).get("value")
        if admin_url:
            host = re.sub(r'^[^/]*//', '', admin_url).split('/')[0].split(':')[0]
        else:
            host = tf_outputs.get("management_public_ip", {}).get("value")

    if not password and tfvars_path:
        password = parse_password_from_tfvars(tfvars_path)

    if not host:
        print_error("Pexip Management Node IP address could not be discovered. Specify --host.")
        sys.exit(1)

    if not password:
        print_error("Pexip admin password could not be discovered. Specify --password.")
        sys.exit(1)

    check_port = 443
    check_host = host
    if ":" in host:
        parts = host.split(":")
        check_host = parts[0]
        try:
            check_port = int(parts[1])
        except ValueError:
            pass

    print_info(f"Connecting to Management Node at {check_host}:{check_port}...")
    if not is_port_open(check_host, check_port, timeout=3):
        print_error(f"Pexip Management Node port {check_port} is unreachable. Make sure the node is online.")
        sys.exit(1)

    base_url = f"https://{host}/api/admin/configuration/v1"
    session = requests.Session()
    session.auth = ('admin', password)
    session.headers.update({
        'Content-Type': 'application/json',
        'Accept': 'application/json'
    })

    try:
        # 1. Fetch assigned certificate URIs from management_vm
        print_info("Fetching Management Node certificate assignments...")
        res_mgmt = session.get(f"{base_url}/management_vm/", verify=args.verify_ssl, timeout=10)
        if res_mgmt.status_code != 200:
            print_error(f"Failed to query management_vm: HTTP {res_mgmt.status_code}")
            sys.exit(1)
        
        mgmt_certs = set()
        mgmt_objs = res_mgmt.json().get("objects", [])
        for obj in mgmt_objs:
            cert_uri = obj.get("tls_certificate")
            if cert_uri:
                mgmt_certs.add(cert_uri)

        # 2. Fetch assigned certificate URIs from worker_vm (Conferencing Nodes)
        print_info("Fetching Conferencing Node certificate assignments...")
        res_worker = session.get(f"{base_url}/worker_vm/", verify=args.verify_ssl, timeout=10)
        if res_worker.status_code != 200:
            print_error(f"Failed to query worker_vm: HTTP {res_worker.status_code}")
            sys.exit(1)
        
        worker_certs = set()
        worker_objs = res_worker.json().get("objects", [])
        for obj in worker_objs:
            cert_uri = obj.get("tls_certificate")
            if cert_uri:
                worker_certs.add(cert_uri)
        assigned_uris = mgmt_certs.union(worker_certs)
        print_info(f"Currently assigned certificate URIs: {list(assigned_uris)}")

        # 3. Fetch all certificate objects in keystore
        print_info("Fetching all TLS certificates from keystore...")
        res_certs = session.get(f"{base_url}/tls_certificate/", verify=args.verify_ssl, timeout=10)
        if res_certs.status_code != 200:
            print_error(f"Failed to query tls_certificate: HTTP {res_certs.status_code}")
            sys.exit(1)

        all_certs = res_certs.json().get("objects", [])
        print_info(f"Found {len(all_certs)} total certificates in keystore.")

        # Safety Check: Ensure that none of the active node assignments are still using self-signed certs.
        # This guarantees that Let's Encrypt certificates have been successfully assigned
        # before we start deleting unused certificates.
        assigned_self_signed = []
        for uri in assigned_uris:
            cert_obj = next((c for c in all_certs if c.get("resource_uri") == uri), None)
            if cert_obj:
                pem = cert_obj.get("certificate", "")
                details = get_cert_details(pem)
                # Issuer equals Subject indicates a self-signed certificate
                if details["issuer"] != "Unknown" and details["issuer"] == details["subject"]:
                    assigned_self_signed.append(details["subject"])

        if assigned_self_signed:
            print_warn("Some active VMs are still assigned default self-signed certificates:")
            for subj in assigned_self_signed:
                print_warn(f"  - {subj}")
            print_error("Aborting cleanup: Let's Encrypt certificates are not yet assigned to all nodes.")
            sys.exit(1)

        unused_certs = []
        for cert in all_certs:
            uri = cert.get("resource_uri")
            subject = cert.get("subject_name", "Unknown")
            if uri not in assigned_uris:
                unused_certs.append(cert)

        if not unused_certs:
            print_success("No unused certificates found in the Pexip keystore. Everything is clean!")
            sys.exit(0)

        print_warn(f"Found {len(unused_certs)} unused certificate(s):")
        for cert in unused_certs:
            uri = cert.get("resource_uri")
            subject = cert.get("subject_name", "Unknown")
            pem_string = cert.get("certificate", "")
            
            details = get_cert_details(pem_string)
            is_self_signed = "Yes" if details["issuer"] == details["subject"] else "No"
            
            print_warn(f"  - Subject:     {subject}")
            print_warn(f"    URI:         {uri}")
            print_warn(f"    Issuer:      {details['issuer']}")
            print_warn(f"    Expires:     {details['expires']}")
            print_warn(f"    Self-Signed: {is_self_signed}")
            print_warn("")

        # 4. Clean up unused certificates
        for cert in unused_certs:
            uri = cert.get("resource_uri")
            subject = cert.get("subject_name", "Unknown")
            pem_string = cert.get("certificate", "")
            details = get_cert_details(pem_string)
            is_self_signed = "Yes" if details["issuer"] == details["subject"] else "No"
            
            should_delete = False
            if args.delete_all:
                should_delete = True
            else:
                try:
                    confirm = input(f"Delete unused certificate '{subject}' [Issuer: {details['issuer']}, Self-Signed: {is_self_signed}] ({uri})? (y/N): ")
                    if confirm.lower().strip() in ('y', 'yes'):
                        should_delete = True
                except (KeyboardInterrupt, EOFError):
                    print("\nAborted.")
                    sys.exit(0)

            if should_delete:
                print_info(f"Deleting certificate '{subject}'...")
                del_url = f"https://{host}{uri}"
                res_del = session.delete(del_url, verify=args.verify_ssl, timeout=10)
                if res_del.status_code in (200, 204):
                    print_success(f"Successfully deleted certificate '{subject}'.")
                else:
                    print_error(f"Failed to delete certificate '{subject}': HTTP {res_del.status_code}")

        print_success("Cleanup process complete.")

    except Exception as e:
        print_error(f"An error occurred: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
