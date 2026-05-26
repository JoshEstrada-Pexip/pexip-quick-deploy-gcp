# ============================================================================
# Pexip Quick Deploy - root module
#
# Deploys Pexip Infinity on GCP end-to-end:
#   1. VPC + subnet + firewall rules + service account
#   2. Copies Pexip published images into this project
#   3. Generates Pexip-compatible password hashes via a local helper script
#      (replaces the pexip terraform provider's *_password_hash resources -
#      they were pure-local computations but lived in state, which caused
#      destroy-time fragility because terraform refreshes Pexip resources
#      via the Manager API and the admin firewall blocks Cloud Shell).
#   4. Renders the Management Node bootstrap JSON inline (was the pexip
#      provider's data.pexip_infinity_manager_config) and injects it as
#      GCE metadata. The Pexip image picks it up on first boot, no SSH.
#   5. Waits for the Management API to be reachable.
#   6. Registers Conferencing Nodes via a local helper script that POSTs
#      to /api/admin/configuration/v1/worker_vm/ once, captures the
#      generated bootstrap configs, and writes them to a JSON file.
#   7. Boots the conf VMs with those bootstrap configs in metadata.
#   8. Removes the bootstrap metadata after deploy (it contains password
#      hashes).
#
# Critical design choice: NO pexip terraform provider resources exist in
# state. Everything Pexip-related is either pure-local (hashes, bootstrap
# JSON) or executed once as a side effect (conf-node registration). That
# means `terraform destroy` only deletes GCP resources and never needs to
# call the Manager API, which is what was breaking before.
# ============================================================================

locals {
  # Manager always lives in a single zone (var.zone_letter). Conferencing
  # Nodes can spread across zones if var.transcoding_zones is set; otherwise
  # they default to the Manager's zone.
  zone             = "${var.region}-${var.zone_letter}"
  manager_hostname = var.enable_acme ? var.acme_manager_hostname : "pexip-mgr"
  conf_hostname    = var.enable_acme ? var.acme_conf_hostname_prefix : "pexip-conf"
  # GCP routes everything through the gateway, so the VM sees a /32.
  pexip_netmask = "255.255.255.255"

  # Zone for each conf node, round-robined over var.transcoding_zones (or
  # all in local.zone if the list is empty). Computing this once and
  # indexing by count.index keeps the per-resource logic readable.
  effective_zones = length(var.transcoding_zones) > 0 ? var.transcoding_zones : [var.zone_letter]
  conf_zones = [
    for i in range(var.transcoding_node_count) :
    "${var.region}-${local.effective_zones[i % length(local.effective_zones)]}"
  ]

  # Inline the Manager bootstrap config the Pexip GCP image expects. This
  # mirrors what the provider's data.pexip_infinity_manager_config produced:
  # a single-line JSON object stored under metadata key management_node_config.
  # Format reverse-engineered from
  # github.com/pexip/terraform-provider-infinity/internal/provider/infinity_manager_config_model.go
  manager_bootstrap_config = jsonencode({
    hostname = local.manager_hostname
    domain   = var.pexip_domain
    ip       = google_compute_address.manager_private.address
    mask     = local.pexip_netmask
    gw       = google_compute_subnetwork.pexip.gateway_address
    # Pexip's bootstrap takes single strings here (not arrays), so join
    # with spaces if the user gave multiple. Conf Nodes use the array
    # via the system_location dns_servers/ntp_servers resources instead.
    dns                   = join(" ", var.dns_servers)
    ntp                   = join(" ", var.ntp_servers)
    user                  = "admin"
    pass                  = data.external.pexip_hashes.result.web_hash
    admin_password        = data.external.pexip_hashes.result.ssh_hash
    error_reports         = false
    enable_analytics      = false
    contact_email_address = var.pexip_contact_email
  })

  # Description of every Conferencing Node, fed into register-conf-nodes.sh.
  # Built here so the script's input is well-typed JSON, not bash args.
  conf_node_specs = [
    for i in range(var.transcoding_node_count) : {
      name               = "${local.conf_hostname}-${i + 1}"
      hostname           = "${local.conf_hostname}-${i + 1}"
      domain             = var.pexip_domain
      address            = google_compute_address.conf_private[i].address
      netmask            = local.pexip_netmask
      gateway            = google_compute_subnetwork.pexip.gateway_address
      password_hash      = data.external.pexip_hashes.result.ssh_hash
      static_nat_address = try(google_compute_address.conf_public[i].address, "")
    }
  ]
}

# ----------------------------------------------------------------------------
# Network
# ----------------------------------------------------------------------------

resource "google_compute_network" "pexip" {
  name                    = var.network_name
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "pexip" {
  name          = "${var.network_name}-${var.region}"
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.pexip.id
}

resource "google_compute_address" "manager_public" {
  name   = "${local.manager_hostname}-public"
  region = var.region
}

resource "google_compute_address" "manager_private" {
  name         = "${local.manager_hostname}-private"
  subnetwork   = google_compute_subnetwork.pexip.id
  address_type = "INTERNAL"
  region       = var.region
}

resource "google_compute_address" "conf_public" {
  count  = var.conf_nodes_public ? var.transcoding_node_count : 0
  name   = "${local.conf_hostname}-${count.index + 1}-public"
  region = var.region
}

resource "google_compute_address" "conf_private" {
  count        = var.transcoding_node_count
  name         = "${local.conf_hostname}-${count.index + 1}-private"
  subnetwork   = google_compute_subnetwork.pexip.id
  address_type = "INTERNAL"
  region       = var.region
}

# ----------------------------------------------------------------------------
# Firewall
# ----------------------------------------------------------------------------

resource "google_compute_firewall" "admin_access" {
  name    = "${var.network_name}-admin-access"
  network = google_compute_network.pexip.name

  source_ranges = var.management_access_cidrs
  target_tags   = ["pexip-manager"]

  allow {
    protocol = "tcp"
    ports    = ["22", "443", "8443"]
  }
  allow {
    protocol = "icmp"
  }
}

resource "google_compute_firewall" "conf_web" {
  name    = "${var.network_name}-conf-web"
  network = google_compute_network.pexip.name

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["pexip-conf"]

  # Only the user-facing conferencing port (443). We deliberately do NOT
  # open tcp:8443 (Pexip's provisioning interface) - this stack delivers
  # the bootstrap config via GCE metadata at first boot, so 8443 never
  # needs to be reachable from outside the VPC. If a user ever needs to
  # fall back to the manual XML upload path (e.g. metadata bootstrap
  # failed), they can temporarily open it:
  #   gcloud compute firewall-rules create pexip-conf-provisioning \
  #     --network=pexip-quick-net --source-ranges=<their-laptop-cidr> \
  #     --target-tags=pexip-conf --allow=tcp:8443
  # And delete the rule once the node is up.
  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
}

resource "google_compute_firewall" "conf_signaling" {
  name    = "${var.network_name}-conf-signaling"
  network = google_compute_network.pexip.name

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["pexip-conf"]

  allow {
    protocol = "tcp"
    ports    = ["1720", "5060", "5061", "33000-39999"]
  }
  allow {
    protocol = "udp"
    ports    = ["5060", "40000-49999"]
  }
}

resource "google_compute_firewall" "internal" {
  name    = "${var.network_name}-internal"
  network = google_compute_network.pexip.name

  source_ranges = [var.subnet_cidr]
  target_tags   = ["pexip-manager", "pexip-conf"]

  allow { protocol = "tcp" }
  allow { protocol = "udp" }
  allow { protocol = "icmp" }
  # Pexip nodes establish an IPsec ESP tunnel between Manager and each
  # Conferencing Node for the management/sync channel. GCP's
  # default-allow-internal rule doesn't include ESP, and neither did
  # earlier versions of this stack - the symptom was the conf node
  # showing as "registered but never contacted" in the Live View
  # because it couldn't actually phone home.
  # Pexip docs: https://docs.pexip.com/admin/google_vpc_network.htm
  allow { protocol = "esp" }
}

# ----------------------------------------------------------------------------
# Service account for the VMs
# ----------------------------------------------------------------------------

resource "google_service_account" "pexip" {
  account_id   = "pexip-quick-sa"
  display_name = "Pexip Quick Deploy"
}

# ----------------------------------------------------------------------------
# Copy Pexip's published images into this project.
# ----------------------------------------------------------------------------

resource "google_compute_image" "management" {
  name         = "pexip-quick-${var.pexip_management_source_image}"
  source_image = "projects/${var.pexip_source_image_project}/global/images/${var.pexip_management_source_image}"
}

resource "google_compute_image" "conferencing" {
  name         = "pexip-quick-${var.pexip_conferencing_source_image}"
  source_image = "projects/${var.pexip_source_image_project}/global/images/${var.pexip_conferencing_source_image}"
}

# ============================================================================
# Password hashes
#
# external data source runs scripts/generate-hashes.sh once at plan time.
# That script emits {web_hash, ssh_hash} as JSON, both matching the formats
# the Pexip provider produced (pbkdf2_sha256$36000$... and $6$rounds=5000$...).
# Pure-local: no API calls, no state-tracked drift.
# ============================================================================

data "external" "pexip_hashes" {
  program = ["${path.module}/../scripts/generate-hashes.sh"]
  query = {
    password = var.pexip_admin_password
  }
}

# ============================================================================
# Management Node
# ============================================================================

resource "random_string" "manager_disk_key" {
  length  = 32
  special = true
}

resource "google_compute_instance" "manager" {
  name             = local.manager_hostname
  zone             = local.zone
  machine_type     = var.management_machine_type
  min_cpu_platform = "Intel Cascade Lake"

  metadata = {
    management_node_config = local.manager_bootstrap_config
  }

  boot_disk {
    disk_encryption_key_raw = base64encode(random_string.manager_disk_key.result)
    initialize_params {
      image = google_compute_image.management.self_link
      type  = "pd-ssd"
    }
  }

  tags = ["pexip-manager"]

  network_interface {
    network    = google_compute_network.pexip.id
    subnetwork = google_compute_subnetwork.pexip.id
    network_ip = google_compute_address.manager_private.address

    access_config {
      nat_ip = google_compute_address.manager_public.address
    }
  }

  service_account {
    email  = google_service_account.pexip.email
    scopes = ["cloud-platform"]
  }

  lifecycle {
    ignore_changes = [metadata]
  }
}

resource "null_resource" "wait_for_manager" {
  depends_on = [google_compute_instance.manager]

  triggers = {
    instance_id = google_compute_instance.manager.id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      url="https://${google_compute_address.manager_public.address}/admin/login/"
      echo "Waiting for Pexip Management Node API at $url"
      echo "(first boot takes 3-7 minutes - VM boots, applies metadata, starts DB+web tier)"
      start=$SECONDS
      for i in $(seq 1 60); do
        # curl's --write-out already prints 000 on connection failure /
        # timeout / DNS error - no need for an OR fallback (which would
        # double up to "000000" and look broken). Default the var so it's
        # never empty if curl itself fails to launch.
        status=000
        status=$(curl --silent --insecure --location \
          --output /dev/null --write-out '%%{http_code}' \
          --max-time 5 "$url")
        elapsed=$((SECONDS - start))
        if [ "$status" = "200" ]; then
          echo "  Management Node is ready (took $${elapsed}s, attempt $i)"
          # Brief settle so the DB-backed REST endpoints stabilise before
          # we start hitting them with the conf-node registration script.
          sleep 15
          exit 0
        fi
        if [ "$status" = "000" ] || [ "$status" = "0" ] || [ -z "$status" ]; then
          status_msg="Connection Failed (Pexip Manager API unreachable or booting)"
        else
          status_msg="HTTP $status"
        fi
        echo "  [$${elapsed}s elapsed, attempt $i/60] $status_msg - waiting 10s"
        sleep 10
      done
      echo "Timed out after 10 minutes waiting for Management Node." >&2
      echo "Check the VM serial console: gcloud compute instances get-serial-port-output ${google_compute_instance.manager.name} --zone=${local.zone}" >&2
      exit 1
    EOT
  }
}

resource "null_resource" "manager_metadata_cleanup" {
  depends_on = [null_resource.wait_for_manager]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      gcloud compute instances remove-metadata ${google_compute_instance.manager.name} \
        --project ${var.project_id} \
        --zone ${local.zone} \
        --keys management_node_config
    EOT
  }
}

# ============================================================================
# Conferencing Nodes
#
# register-conf-nodes.sh hits the Manager API once after wait_for_manager
# succeeds, creates the system_location + worker_vm records, and writes
# their bootstrap configs to ${path.module}/conf-configs.json. Terraform
# reads that file via local_file and feeds each config to the matching VM's
# metadata. NO pexip provider resources are in state - so on destroy,
# terraform just deletes the GCP VMs and the Pexip-side records vanish
# with the Manager.
# ============================================================================

resource "null_resource" "register_conf_nodes" {
  depends_on = [null_resource.wait_for_manager]

  # Re-run if the set of conf nodes, or the DNS/NTP it depends on, changes.
  triggers = {
    nodes_hash = sha256(jsonencode(local.conf_node_specs))
    dns_ntp    = "${join(",", var.dns_servers)}|${join(",", var.ntp_servers)}"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "${path.module}/../scripts/register-conf-nodes.sh"
    environment = {
      PEXIP_MANAGER_IP      = google_compute_address.manager_public.address
      PEXIP_ADMIN_PASSWORD  = var.pexip_admin_password
      PEXIP_CONF_NODES_JSON = jsonencode(local.conf_node_specs)
      PEXIP_DNS_SERVERS     = join(",", var.dns_servers)
      PEXIP_NTP_SERVERS     = join(",", var.ntp_servers)
      PEXIP_OUT_DIR         = path.module
    }
  }
}

data "local_file" "conf_configs" {
  depends_on = [null_resource.register_conf_nodes]
  filename   = "${path.module}/conf-configs.json"
}

locals {
  # Decode the JSON file the script wrote. Each entry in .configs is a
  # base64-encoded bootstrap blob; conferencing_node_config metadata expects
  # the raw blob, so we decode here.
  conf_bootstrap_configs = [
    for c in jsondecode(data.local_file.conf_configs.content).configs : base64decode(c)
  ]
}

resource "random_string" "conf_disk_key" {
  count   = var.transcoding_node_count
  length  = 32
  special = true
}

resource "google_compute_instance" "conf" {
  count            = var.transcoding_node_count
  name             = "${local.conf_hostname}-${count.index + 1}"
  zone             = local.conf_zones[count.index]
  machine_type     = var.transcoding_machine_type
  min_cpu_platform = "Intel Cascade Lake"

  metadata = {
    conferencing_node_config = local.conf_bootstrap_configs[count.index]
  }

  boot_disk {
    disk_encryption_key_raw = base64encode(random_string.conf_disk_key[count.index].result)
    initialize_params {
      image = google_compute_image.conferencing.self_link
      type  = "pd-ssd"
    }
  }

  tags = ["pexip-conf"]

  network_interface {
    network    = google_compute_network.pexip.id
    subnetwork = google_compute_subnetwork.pexip.id
    network_ip = google_compute_address.conf_private[count.index].address

    # Public IP is optional - when var.conf_nodes_public is false the conf
    # node only has an internal address and must be reached via Cloud VPN,
    # IAP, or VPC peering. dynamic{} lets us include / omit the block
    # cleanly without count tricks on the parent resource.
    dynamic "access_config" {
      for_each = var.conf_nodes_public ? [1] : []
      content {
        nat_ip = google_compute_address.conf_public[count.index].address
      }
    }
  }

  service_account {
    email  = google_service_account.pexip.email
    scopes = ["cloud-platform"]
  }

  lifecycle {
    ignore_changes = [metadata]
  }
}

resource "null_resource" "conf_metadata_cleanup" {
  count      = var.transcoding_node_count
  depends_on = [google_compute_instance.conf]

  triggers = {
    instance_id = google_compute_instance.conf[count.index].id
  }

  # Wait a bit, then clear the bootstrap metadata. We don't health-check the
  # conf node here because the Management Node UI will show sync state.
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      sleep 60
      gcloud compute instances remove-metadata ${google_compute_instance.conf[count.index].name} \
        --project ${var.project_id} \
        --zone ${local.conf_zones[count.index]} \
        --keys conferencing_node_config
    EOT
  }
}

# ============================================================================
# Optional: Let's Encrypt certs via Cloudflare DNS-01
#
# When var.enable_acme is true, this block:
#   1. Registers an ACME account (account key kept in tfstate).
#   2. Issues a cert for the Manager FQDN.
#   3. Issues a SAN cert covering every Conferencing Node FQDN.
#   4. POSTs both certs into Pexip's TLS keystore via the Manager API and
#      assigns them to the matching nodes (scripts/install-cert.sh).
#
# Cert grouping: Manager gets its own cert. Conf nodes share one SAN cert
# because they live in the same system_location and we want SIP routing
# to treat them as round-robinnable peers of the same identity. If this
# stack ever spreads conf nodes across multiple regions, group them by
# region and issue one SAN cert per group - the rest of the plumbing
# already supports that.
#
# Staging by default (var.acme_use_production = false). The cert will be
# real but browser-untrusted until you flip that. Let's Encrypt's prod
# rate limits (5 dup certs/domain/week) are easy to burn through during
# iteration, so iterate against staging first.
# ============================================================================

locals {
  acme_enabled         = var.enable_acme
  acme_manager_fqdn    = var.enable_acme ? "${var.acme_manager_hostname}.${var.acme_domain}" : ""
  acme_conf_fqdns      = var.enable_acme ? [for i in range(var.transcoding_node_count) : "${var.acme_conf_hostname_prefix}-${i + 1}.${var.acme_domain}"] : []
  acme_directory_label = var.acme_use_production ? "PRODUCTION" : "STAGING"
  cloudflare_zone_name = var.cloudflare_zone_name != "" ? var.cloudflare_zone_name : var.acme_domain
}

# Account key for the ACME registration. Held in tfstate alongside the
# Pexip admin password - threat model is unchanged.
resource "tls_private_key" "acme_account" {
  count     = local.acme_enabled ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "acme_registration" "main" {
  count           = local.acme_enabled ? 1 : 0
  account_key_pem = tls_private_key.acme_account[0].private_key_pem
  email_address   = var.acme_email
}

# Manager cert: single hostname, e.g. pexip-mgr.demo.example.com.
#
# depends_on ties issuance to the Pexip deploy completing first. Without
# this, terraform runs ACME in parallel with the conf-node registration
# and we burn Let's Encrypt issuance attempts even when the rest of the
# apply is failing. trimspace() on the token guards against stray
# newlines from setup.sh's read -s prompt (a missed trailing newline
# manifests as Cloudflare 6111 "Invalid format for Authorization header").
resource "acme_certificate" "manager" {
  count              = local.acme_enabled ? 1 : 0
  account_key_pem    = acme_registration.main[0].account_key_pem
  common_name        = local.acme_manager_fqdn
  min_days_remaining = 30

  depends_on = [
    null_resource.wait_for_manager,
    null_resource.register_conf_nodes,
    google_compute_instance.conf,
  ]

  dns_challenge {
    provider = "cloudflare"
    config = {
      CF_DNS_API_TOKEN = trimspace(var.cloudflare_api_token)
    }
  }
}

# Conf nodes share one SAN cert (same Pexip system_location -> same SIP
# identity). The first conf FQDN is the CN, the rest are SANs.
resource "acme_certificate" "conf" {
  count                     = local.acme_enabled && var.transcoding_node_count > 0 ? 1 : 0
  account_key_pem           = acme_registration.main[0].account_key_pem
  common_name               = local.acme_conf_fqdns[0]
  subject_alternative_names = slice(local.acme_conf_fqdns, 1, length(local.acme_conf_fqdns))
  min_days_remaining        = 30

  depends_on = [
    null_resource.wait_for_manager,
    null_resource.register_conf_nodes,
    google_compute_instance.conf,
    acme_certificate.manager,
  ]

  dns_challenge {
    provider = "cloudflare"
    config = {
      CF_DNS_API_TOKEN = trimspace(var.cloudflare_api_token)
    }
  }
}

# Push both certs into Pexip's TLS keystore via the Management API and
# assign them to the right nodes. Side-effect only - nothing tracked in
# state, same pattern as register-conf-nodes.sh.
resource "null_resource" "install_acme_certs" {
  count = local.acme_enabled ? 1 : 0

  depends_on = [
    null_resource.wait_for_manager,
    null_resource.register_conf_nodes,
    acme_certificate.manager,
    acme_certificate.conf,
  ]

  # Re-run when either cert is reissued (Terraform reissues automatically
  # when min_days_remaining triggers) or when the conf node set changes.
  triggers = {
    manager_cert_id = local.acme_enabled ? acme_certificate.manager[0].id : ""
    conf_cert_id    = local.acme_enabled && var.transcoding_node_count > 0 ? acme_certificate.conf[0].id : ""
    conf_fqdns      = join(",", local.acme_conf_fqdns)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "${path.module}/../scripts/install-cert.sh"
    environment = {
      PEXIP_MANAGER_IP     = google_compute_address.manager_public.address
      PEXIP_ADMIN_PASSWORD = var.pexip_admin_password
      MANAGER_FQDN         = local.acme_manager_fqdn
      MANAGER_CERT_PEM     = local.acme_enabled ? acme_certificate.manager[0].certificate_pem : ""
      MANAGER_ISSUER_PEM   = local.acme_enabled ? acme_certificate.manager[0].issuer_pem : ""
      MANAGER_KEY_PEM      = local.acme_enabled ? acme_certificate.manager[0].private_key_pem : ""
      CONF_FQDNS_CSV       = join(",", local.acme_conf_fqdns)
      CONF_CERT_PEM        = local.acme_enabled && var.transcoding_node_count > 0 ? acme_certificate.conf[0].certificate_pem : ""
      CONF_ISSUER_PEM      = local.acme_enabled && var.transcoding_node_count > 0 ? acme_certificate.conf[0].issuer_pem : ""
      CONF_KEY_PEM         = local.acme_enabled && var.transcoding_node_count > 0 ? acme_certificate.conf[0].private_key_pem : ""
    }
  }
}

# ============================================================================
# Automated Cloudflare DNS records (A and SIP/SIPS/Pexapp SRV)
# ============================================================================

data "cloudflare_zone" "pexip" {
  count = local.acme_enabled && var.manage_dns_records ? 1 : 0
  filter = {
    name = local.cloudflare_zone_name
  }
}

# A record for the Management Node
resource "cloudflare_dns_record" "manager_a" {
  count   = local.acme_enabled && var.manage_dns_records ? 1 : 0
  zone_id = data.cloudflare_zone.pexip[0].id
  name    = local.acme_manager_fqdn
  content = google_compute_address.manager_public.address
  type    = "A"
  proxied = false
  ttl     = 300
}

# A records for the Conferencing Nodes
resource "cloudflare_dns_record" "conf_a" {
  count   = local.acme_enabled && var.manage_dns_records ? var.transcoding_node_count : 0
  zone_id = data.cloudflare_zone.pexip[0].id
  name    = local.acme_conf_fqdns[count.index]
  content = var.conf_nodes_public ? google_compute_address.conf_public[count.index].address : google_compute_address.conf_private[count.index].address
  type    = "A"
  proxied = false
  ttl     = 300
}

# SRV records for secure SIP TLS routing
resource "cloudflare_dns_record" "sips_srv" {
  count   = local.acme_enabled && var.manage_dns_records && var.transcoding_node_count > 0 ? var.transcoding_node_count : 0
  zone_id = data.cloudflare_zone.pexip[0].id
  name    = "_sips._tcp.${var.acme_domain}"
  type    = "SRV"
  ttl     = 300

  data = {
    service  = "_sips"
    proto    = "_tcp"
    name     = var.acme_domain
    priority = 10
    weight   = 10
    port     = 5061
    target   = local.acme_conf_fqdns[count.index]
  }
}

# SRV records for non-secure SIP TCP routing
resource "cloudflare_dns_record" "sip_srv" {
  count   = local.acme_enabled && var.manage_dns_records && var.transcoding_node_count > 0 ? var.transcoding_node_count : 0
  zone_id = data.cloudflare_zone.pexip[0].id
  name    = "_sip._tcp.${var.acme_domain}"
  type    = "SRV"
  ttl     = 300

  data = {
    service  = "_sip"
    proto    = "_tcp"
    name     = var.acme_domain
    priority = 10
    weight   = 10
    port     = 5060
    target   = local.acme_conf_fqdns[count.index]
  }
}

# SRV records for Pexip application registration (WebRTC/Pexip Connect app)
resource "cloudflare_dns_record" "pexapp_srv" {
  count   = local.acme_enabled && var.manage_dns_records && var.transcoding_node_count > 0 ? var.transcoding_node_count : 0
  zone_id = data.cloudflare_zone.pexip[0].id
  name    = "_pexapp._tcp.${var.acme_domain}"
  type    = "SRV"
  ttl     = 300

  data = {
    service  = "_pexapp"
    proto    = "_tcp"
    name     = var.acme_domain
    priority = 10
    weight   = 10
    port     = 443
    target   = local.acme_conf_fqdns[count.index]
  }
}
