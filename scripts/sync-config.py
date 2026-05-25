#!/usr/bin/env python3
"""
Pexip Infinity Stage 2 Configuration Sync Tool
Idempotently configures licenses, Virtual Meeting Rooms (VMRs), and gateway routing rules.
"""

import sys
import os
import argparse
import urllib3

# Suppress urllib3 SSL warnings for self-signed certificates (default on Pexip initial boots)
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

try:
    import yaml
    import requests
except ImportError:
    print("\033[91mError: Required Python packages 'requests' or 'pyyaml' are not installed.\033[0m")
    print("Please run this script via './scripts/configure-platform.sh' to install dependencies automatically.")
    sys.exit(1)

# ANSI escape codes for coloring terminal output
COLOR_GREEN = "\033[92m"
COLOR_YELLOW = "\033[93m"
COLOR_RED = "\033[91m"
COLOR_CYAN = "\033[96m"
COLOR_MAGENTA = "\033[95m"
COLOR_RESET = "\033[0m"

def print_success(msg):
    print(f"{COLOR_GREEN}[SUCCESS] {msg}{COLOR_RESET}")

def print_info(msg):
    print(f"{COLOR_CYAN}[INFO] {msg}{COLOR_RESET}")

def print_update(msg):
    print(f"{COLOR_YELLOW}[UPDATED] {msg}{COLOR_RESET}")

def print_skip(msg):
    print(f"{COLOR_MAGENTA}[SKIPPED] {msg}{COLOR_RESET}")

def print_error(msg):
    print(f"{COLOR_RED}[ERROR] {msg}{COLOR_RESET}", file=sys.stderr)

class PexipConfigurator:
    def __init__(self, host, password, verify_ssl=False):
        self.host = host
        self.verify_ssl = verify_ssl
        self.base_url = f"https://{host}/api/admin/configuration/v1"
        self.session = requests.Session()
        self.session.auth = ('admin', password)
        self.session.headers.update({
            'Content-Type': 'application/json',
            'Accept': 'application/json'
        })
        self.locations_map = {}
        self.has_errors = False
        self.is_licensed = False

    def request(self, method, endpoint, json_data=None, params=None):
        """Wrapper around requests.Session requests to handle basic API errors."""
        url = f"{self.base_url}/{endpoint.strip('/')}/"
        try:
            response = self.session.request(
                method, url, json=json_data, params=params, verify=self.verify_ssl, timeout=15
            )
            if response.status_code in (200, 201, 202, 204):
                return response
            elif response.status_code == 401:
                print_error("Authentication failed. Please verify the admin password.")
                sys.exit(1)
            else:
                self.has_errors = True
                try:
                    err_json = response.json()
                    print_error(f"API returned {response.status_code}: {err_json}")
                except Exception:
                    print_error(f"API returned {response.status_code}: {response.text}")
                return response
        except requests.exceptions.SSLError as e:
            print_error(f"SSL verification failed. Try passing --verify-ssl=False or running the script in bypass mode. Error: {e}")
            sys.exit(1)
        except requests.exceptions.ConnectionError as e:
            print_error(f"Could not connect to Pexip Management Node at https://{self.host}. Error: {e}")
            sys.exit(1)
        except Exception as e:
            self.has_errors = True
            print_error(f"An unexpected error occurred during the API call: {e}")
            return None

    def load_locations(self):
        """Pre-fetch and cache locations to resolve location names to resource URIs."""
        print_info("Fetching system locations...")
        response = self.request("GET", "system_location", params={"limit": 100})
        if response and response.status_code == 200:
            data = response.json()
            for loc in data.get("objects", []):
                name = loc.get("name")
                resource_uri = loc.get("resource_uri")
                if name and resource_uri:
                    self.locations_map[name] = resource_uri
            print_success(f"Cached {len(self.locations_map)} system locations.")
        else:
            self.has_errors = True
            print_error("Failed to fetch system locations.")

    def load_licenses(self):
        """Check if the Management Node has any active licenses applied (retrying if needed to allow activation propagation)."""
        import time
        print_info("Checking licensing status...")
        for attempt in range(1, 4):
            response = self.request("GET", "licence")
            if response and response.status_code == 200:
                data = response.json()
                licenses = data.get("objects", [])
                if licenses:
                    self.is_licensed = True
                    print_success(f"Management Node is licensed (found {len(licenses)} license(s)).")
                    return
                else:
                    if attempt < 3:
                        print_info(f"Management Node is unlicensed/trial (attempt {attempt}/3). Retrying in 4 seconds to allow registration to propagate...")
                        time.sleep(4)
                    else:
                        self.is_licensed = False
                        print_info("Management Node is unlicensed/trial (0 licenses found after retries).")
            else:
                self.is_licensed = False
                print_error("Failed to query licensing status. Assuming unlicensed.")
                return

    def sync_license(self, license_key):
        """Idempotently apply the Pexip activation key."""
        if not license_key:
            print_skip("No license_key provided in configuration. Skipping license step.")
            return

        print_info("Checking existing licenses...")
        response = self.request("GET", "licence")
        if response and response.status_code == 200:
            data = response.json()
            # Pexip license key shows up in GET response objects as 'entitlement_id' or 'activation_key'
            existing_keys = [
                lic.get("entitlement_id", "").strip() for lic in data.get("objects", [])
            ]
            clean_key = "".join(license_key.split())
            clean_existing = ["".join(k.split()) for k in existing_keys]
            if clean_key in clean_existing:
                print_skip("License key is already applied.")
                return

            print_info("Applying new license key...")
            payload = {"entitlement_id": clean_key}
            post_response = self.request("POST", "licence", json_data=payload)
            if post_response and post_response.status_code == 201:
                print_success("License key applied successfully.")
                import time
                print_info("Waiting 8 seconds for license activation to register on the platform...")
                time.sleep(8)
            else:
                self.has_errors = True
                print_error("Failed to apply license key. Make sure the node is online and can reach activation.pexip.com.")
        else:
            self.has_errors = True
            print_error("Failed to read license settings.")

    def sync_vmrs(self, vmrs):
        """Idempotently sync Virtual Meeting Rooms (VMRs) and their aliases."""
        if not vmrs:
            print_skip("No VMRs defined in configuration. Skipping VMR step.")
            return

        if not self.is_licensed:
            print_skip("Management Node is unlicensed. Skipping VMR synchronization (requires platform license).")
            return

        print_info(f"Syncing {len(vmrs)} Virtual Meeting Rooms...")
        for vmr in vmrs:
            name = vmr.get("name")
            if not name:
                self.has_errors = True
                print_error("Skipping VMR entry missing 'name' attribute.")
                continue

            # Check if this VMR exists
            response = self.request("GET", "conference", params={"service_type": "conference", "name": name})
            if not response or response.status_code != 200:
                self.has_errors = True
                print_error(f"Could not verify existence of VMR '{name}'. Skipping.")
                continue

            data = response.json()
            existing_objects = data.get("objects", [])

            # Format aliases array for Pexip API
            aliases_payload = [{"alias": a} for a in vmr.get("aliases", [])]

            desired_payload = {
                "name": name,
                "service_type": "conference",
                "description": vmr.get("description", ""),
                "tag": vmr.get("tag", ""),
                "allow_guests": vmr.get("allow_guests", True),
                "pin": vmr.get("pin", ""),
                "guest_pin": vmr.get("guest_pin", ""),
                "host_view": vmr.get("host_view", "one_main_seven_pips"),
                "guest_view": vmr.get("guest_view", "one_main_seven_pips"),
                "aliases": aliases_payload
            }

            if not existing_objects:
                # Create VMR
                print_info(f"VMR '{name}' not found. Creating it...")
                create_response = self.request("POST", "conference", json_data=desired_payload)
                if create_response and create_response.status_code == 201:
                    print_success(f"Created VMR '{name}' with aliases: {', '.join(vmr.get('aliases', []))}")
                else:
                    self.has_errors = True
                    print_error(f"Failed to create VMR '{name}'.")
            else:
                # Update existing VMR
                existing_vmr = existing_objects[0]
                vmr_id = existing_vmr.get("id")
                resource_uri = existing_vmr.get("resource_uri")

                # Compare fields to determine if we need a PATCH
                needs_update = False
                patch_payload = {}

                # Fields to verify
                fields_to_compare = ["description", "tag", "allow_guests", "pin", "guest_pin", "host_view", "guest_view"]
                for field in fields_to_compare:
                    existing_val = existing_vmr.get(field)
                    desired_val = desired_payload.get(field)

                    # For layout views (guest_view/host_view), the API may return null/None (e.g. for certain service types or licenses).
                    # If existing is None, treat it as matching the desired value to prevent infinite PATCH loops.
                    if field in ("guest_view", "host_view") and existing_val is None:
                        existing_val = desired_val

                    # Note: API might return empty strings as null, normalize comparison
                    if (existing_val or "") != (desired_val or ""):
                        needs_update = True
                        patch_payload[field] = desired_val

                # Compare aliases (nested replace list)
                existing_aliases = {a.get("alias") for a in existing_vmr.get("aliases", []) if a.get("alias")}
                desired_aliases = set(vmr.get("aliases", []))
                if existing_aliases != desired_aliases:
                    needs_update = True
                    patch_payload["aliases"] = aliases_payload

                if needs_update:
                    print_info(f"VMR '{name}' exists but has modified configurations. Updating...")
                    patch_endpoint = f"conference/{vmr_id}"
                    patch_response = self.request("PATCH", patch_endpoint, json_data=patch_payload)
                    if patch_response and patch_response.status_code in (200, 202, 204):
                        print_update(f"Updated VMR '{name}'.")
                    else:
                        self.has_errors = True
                        print_error(f"Failed to update VMR '{name}'.")
                else:
                    print_skip(f"VMR '{name}' is already up-to-date.")

    def sync_gateway_rules(self, rules):
        """Idempotently sync Gateway Routing Rules (Dial Plan)."""
        if not rules:
            print_skip("No gateway_rules defined in configuration. Skipping Gateway Rules step.")
            return

        print_info(f"Syncing {len(rules)} Gateway Routing Rules...")
        for rule in rules:
            name = rule.get("name")
            if not name:
                self.has_errors = True
                print_error("Skipping gateway rule entry missing 'name' attribute.")
                continue

            # Check if this is a Teams-specific rule on an unlicensed manager
            called_device_type = rule.get("called_device_type", "external")
            outgoing_protocol = rule.get("outgoing_protocol", "sip")
            is_teams_rule = (called_device_type == "teams_conference" or outgoing_protocol == "teams")
            
            if not self.is_licensed and is_teams_rule:
                print_skip(f"Gateway rule '{name}' is Teams-specific and Management Node is unlicensed. Skipping rule.")
                continue

            # Resolve location URI
            location_name = rule.get("outgoing_location")
            location_uri = ""
            if location_name:
                location_uri = self.locations_map.get(location_name, "")
                if not location_uri:
                    self.has_errors = True
                    print_error(f"Location '{location_name}' not found. Rule '{name}' will use default location.")
            
            # Default to first location in map if not resolved
            if not location_uri and self.locations_map:
                location_uri = list(self.locations_map.values())[0]

            desired_payload = {
                "name": name,
                "description": rule.get("description", ""),
                "priority": rule.get("priority", 100),
                "enable": rule.get("enable", True),
                "match_string": rule.get("match_string"),
                "replace_string": rule.get("replace_string", ""),
                "called_device_type": rule.get("called_device_type", "external"),
                "outgoing_protocol": rule.get("outgoing_protocol", "sip"),
                "outgoing_location": location_uri,
                "call_type": rule.get("call_type", "video"),
                "crypto_mode": rule.get("crypto_mode", "best_effort")
            }

            # Check if this rule exists by name
            response = self.request("GET", "gateway_routing_rule", params={"name": name})
            if not response or response.status_code != 200:
                self.has_errors = True
                print_error(f"Could not verify existence of gateway rule '{name}'. Skipping.")
                continue

            data = response.json()
            existing_objects = data.get("objects", [])

            if not existing_objects:
                # Create Gateway Rule
                print_info(f"Gateway rule '{name}' not found. Creating it...")
                create_response = self.request("POST", "gateway_routing_rule", json_data=desired_payload)
                if create_response and create_response.status_code == 201:
                    print_success(f"Created Gateway Routing Rule '{name}' (Priority {desired_payload['priority']})")
                else:
                    self.has_errors = True
                    print_error(f"Failed to create Gateway Routing Rule '{name}'.")
            else:
                # Update existing rule
                existing_rule = existing_objects[0]
                rule_id = existing_rule.get("id")

                needs_update = False
                patch_payload = {}

                # Fields to verify
                fields_to_compare = [
                    "description", "priority", "enable", "match_string", "replace_string",
                    "called_device_type", "outgoing_protocol", "outgoing_location", "call_type", "crypto_mode"
                ]
                for field in fields_to_compare:
                    existing_val = existing_rule.get(field)
                    desired_val = desired_payload.get(field)
                    # Normalize comparison (e.g. integer vs string representation, empty vs null)
                    if field == "priority" and existing_val is not None:
                        existing_val = int(existing_val)
                    if (existing_val or "") != (desired_val or ""):
                        needs_update = True
                        patch_payload[field] = desired_val

                if needs_update:
                    print_info(f"Gateway rule '{name}' exists but has modified configurations. Updating...")
                    patch_endpoint = f"gateway_routing_rule/{rule_id}"
                    patch_response = self.request("PATCH", patch_endpoint, json_data=patch_payload)
                    if patch_response and patch_response.status_code in (200, 202, 204):
                        print_update(f"Updated Gateway Routing Rule '{name}'.")
                    else:
                        self.has_errors = True
                        print_error(f"Failed to update Gateway Routing Rule '{name}'.")
                else:
                    print_skip(f"Gateway Routing Rule '{name}' is already up-to-date.")

    def sync_users(self, users):
        """Idempotently sync End Users."""
        if not users:
            print_skip("No users defined in configuration. Skipping Users step.")
            return

        print_info(f"Syncing {len(users)} End Users...")
        for user in users:
            email = user.get("primary_email_address")
            if not email:
                self.has_errors = True
                print_error("Skipping User entry missing 'primary_email_address' attribute.")
                continue

            # Check if this user exists
            response = self.request("GET", "end_user", params={"primary_email_address": email})
            if not response or response.status_code != 200:
                self.has_errors = True
                print_error(f"Could not verify existence of user '{email}'. Skipping.")
                continue

            data = response.json()
            existing_objects = data.get("objects", [])

            desired_payload = {
                "primary_email_address": email,
                "first_name": user.get("first_name", ""),
                "last_name": user.get("last_name", ""),
                "display_name": user.get("display_name", ""),
                "telephone_number": user.get("telephone_number", ""),
                "mobile_number": user.get("mobile_number", ""),
                "title": user.get("title", ""),
                "department": user.get("department", ""),
                "avatar_url": user.get("avatar_url", "")
            }

            if not existing_objects:
                # Create End User
                print_info(f"User '{email}' not found. Creating it...")
                create_response = self.request("POST", "end_user", json_data=desired_payload)
                if create_response and create_response.status_code == 201:
                    print_success(f"Created User '{email}'")
                else:
                    self.has_errors = True
                    print_error(f"Failed to create User '{email}'.")
            else:
                # Update existing user
                existing_user = existing_objects[0]
                user_id = existing_user.get("id")

                needs_update = False
                patch_payload = {}

                # Fields to verify
                fields_to_compare = [
                    "first_name", "last_name", "display_name", "telephone_number",
                    "mobile_number", "title", "department", "avatar_url"
                ]
                for field in fields_to_compare:
                    existing_val = existing_user.get(field)
                    desired_val = desired_payload.get(field)
                    if (existing_val or "") != (desired_val or ""):
                        needs_update = True
                        patch_payload[field] = desired_val

                if needs_update:
                    print_info(f"User '{email}' exists but has modified configurations. Updating...")
                    patch_endpoint = f"end_user/{user_id}"
                    patch_response = self.request("PATCH", patch_endpoint, json_data=patch_payload)
                    if patch_response and patch_response.status_code in (200, 202, 204):
                        print_update(f"Updated User '{email}'.")
                    else:
                        self.has_errors = True
                        print_error(f"Failed to update User '{email}'.")
                else:
                    print_skip(f"User '{email}' is already up-to-date.")

    def sync_device_aliases(self, device_aliases):
        """Idempotently sync Device Aliases (Registrations)."""
        if not device_aliases:
            print_skip("No device aliases defined in configuration. Skipping Device Aliases step.")
            return

        print_info(f"Syncing {len(device_aliases)} Device Aliases...")
        for da in device_aliases:
            alias = da.get("device_alias")
            if not alias:
                self.has_errors = True
                print_error("Skipping Device Alias entry missing 'device_alias' attribute.")
                continue

            # Check if this device alias exists (using 'device' endpoint)
            response = self.request("GET", "device", params={"alias": alias})
            if not response or response.status_code != 200:
                self.has_errors = True
                print_error(f"Could not verify existence of device alias '{alias}'. Skipping.")
                continue

            data = response.json()
            existing_objects = data.get("objects", [])

            desired_payload = {
                "alias": alias,
                "description": da.get("device_description", ""),
                "username": da.get("device_username", ""),
                "password": da.get("device_password", ""),
                "tag": da.get("device_tag", ""),
                "primary_owner_email_address": da.get("primary_owner_email_address", "")
            }

            if not existing_objects:
                # Create Device Alias
                print_info(f"Device alias '{alias}' not found. Creating it...")
                create_response = self.request("POST", "device", json_data=desired_payload)
                if create_response and create_response.status_code == 201:
                    print_success(f"Created Device Alias '{alias}'")
                else:
                    self.has_errors = True
                    print_error(f"Failed to create Device Alias '{alias}'.")
            else:
                # Update existing device alias
                existing_da = existing_objects[0]
                da_id = existing_da.get("id")

                needs_update = False
                patch_payload = {}

                # Fields to verify (excluding password from comparison to prevent constant sync writes)
                fields_to_compare = ["description", "username", "tag", "primary_owner_email_address"]
                for field in fields_to_compare:
                    existing_val = existing_da.get(field)
                    desired_val = desired_payload.get(field)
                    if (existing_val or "") != (desired_val or ""):
                        needs_update = True
                        patch_payload[field] = desired_val

                # If we need an update, we should also write the password if it's set in the YAML
                if needs_update:
                    if desired_payload["password"]:
                        patch_payload["password"] = desired_payload["password"]

                    print_info(f"Device alias '{alias}' exists but has modified configurations. Updating...")
                    patch_endpoint = f"device/{da_id}"
                    patch_response = self.request("PATCH", patch_endpoint, json_data=patch_payload)
                    if patch_response and patch_response.status_code in (200, 202, 204):
                        print_update(f"Updated Device Alias '{alias}'.")
                    else:
                        self.has_errors = True
                        print_error(f"Failed to update Device Alias '{alias}'.")
                else:
                    print_skip(f"Device alias '{alias}' is already up-to-date.")

def main():
    parser = argparse.ArgumentParser(description="Pexip Stage 2 Sync Tool")
    parser.add_argument("--host", required=True, help="IP address of the Pexip Management Node")
    parser.add_argument("--password", required=True, help="Admin password for the Pexip Management Node")
    parser.add_argument("--config", default="pexip-config.yaml", help="Path to the pexip-config.yaml file")
    parser.add_argument("--verify-ssl", action="store_true", help="Verify SSL certificate (default: False)")
    args = parser.parse_args()

    # Verify config file exists
    if not os.path.exists(args.config):
        print_error(f"Configuration file not found at '{args.config}'. Please create one first.")
        sys.exit(1)

    print_info(f"Loading configuration from '{args.config}'...")
    try:
        with open(args.config, 'r') as f:
            config_data = yaml.safe_load(f)
    except Exception as e:
        print_error(f"Failed to parse YAML configuration: {e}")
        sys.exit(1)

    if not config_data:
        print_error("Configuration file is empty.")
        sys.exit(1)

    print_info(f"Initializing connection to Pexip Management Node at {args.host}...")
    configurator = PexipConfigurator(args.host, args.password, verify_ssl=args.verify_ssl)

    # 1. Sync License (First thing)
    print_info("--- STEP 1: LICENSE SYNC ---")
    configurator.sync_license(config_data.get("license_key"))
    configurator.load_licenses()

    # Load locations map (required for mapping names to URIs in gateway rules)
    configurator.load_locations()

    # 2. Sync VMRs
    print_info("--- STEP 2: VMR & ALIAS SYNC ---")
    configurator.sync_vmrs(config_data.get("vmrs"))

    # 3. Sync Gateway Rules
    print_info("--- STEP 3: DIAL PLAN SYNC ---")
    configurator.sync_gateway_rules(config_data.get("gateway_rules"))

    # 4. Sync End Users
    print_info("--- STEP 4: USER SYNC ---")
    configurator.sync_users(config_data.get("users"))

    # 5. Sync Device Aliases
    print_info("--- STEP 5: DEVICE ALIAS SYNC ---")
    configurator.sync_device_aliases(config_data.get("device_aliases"))

    if configurator.has_errors:
        print_error("Stage 2 configuration synchronization completed with errors.")
        sys.exit(1)
    else:
        print_success("Stage 2 configuration synchronization completed.")

if __name__ == "__main__":
    main()

