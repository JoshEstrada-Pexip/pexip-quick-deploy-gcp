variable "project_id" {
  description = "GCP project ID where Pexip Infinity will be deployed."
  type        = string
}

variable "region" {
  description = "Primary GCP region (e.g. us-west1)."
  type        = string
  default     = "us-west1"
}

variable "zone_letter" {
  description = "Zone letter inside the region for all VMs (a/b/c/...)."
  type        = string
  default     = "b"
}

variable "network_name" {
  description = "Name for the VPC network this stack will create."
  type        = string
  default     = "pexip-quick-net"
}

variable "subnet_cidr" {
  description = "CIDR block for the Pexip subnet."
  type        = string
  default     = "10.20.0.0/24"
}

variable "management_access_cidrs" {
  description = "CIDR ranges allowed to reach the Pexip admin UI (port 443). Tighten this in production."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "transcoding_node_count" {
  description = "How many Conferencing/Transcoding nodes to deploy."
  type        = number
  default     = 1
}

variable "transcoding_zones" {
  description = <<-EOT
    Zones in the chosen region to spread Conferencing Nodes across. Conf node N
    is placed in zones[N % length(zones)]. Leave empty to put every node in the
    same zone as the Manager (var.zone_letter). Example: ["a", "b", "c"]
    deploys nodes round-robin across us-west1-{a,b,c} (assuming
    var.region = "us-west1"). Useful for HA within a single region.
  EOT
  type        = list(string)
  default     = []
}

variable "conf_nodes_public" {
  description = <<-EOT
    Whether to assign external IP addresses to Conferencing Nodes. When true
    (default), conf nodes are reachable from the public internet on tcp:443 +
    SIP/RTP. When false, conf nodes are internal-only and you must reach them
    via Cloud VPN, IAP tunnel, or VPC peering. The Manager always gets a
    public IP regardless (so Cloud Shell can poll its admin URL during deploy).
  EOT
  type        = bool
  default     = true
}

variable "management_machine_type" {
  description = "Machine type for the Management Node."
  type        = string
  default     = "n2-highcpu-4"
}

variable "transcoding_machine_type" {
  description = "Machine type for each Conferencing Node."
  type        = string
  default     = "n2-highcpu-8"
}

# ----------------------------------------------------------------------------
# Pexip credentials & contact info (used by the bootstrap config)
# ----------------------------------------------------------------------------

variable "pexip_admin_password" {
  description = "Password to set on the Pexip Management Node. Used for both the admin web UI (username 'admin') and the OS-level SSH admin account."
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.pexip_admin_password) >= 8
    error_message = "Admin password must be at least 8 characters."
  }
}

variable "pexip_contact_email" {
  description = "Contact email address Pexip will store with the deployment (used for notifications). Doesn't need to be a working address."
  type        = string
  default     = "admin@example.com"
}

variable "pexip_domain" {
  description = "Internal DNS domain used in the bootstrap config. No real DNS is required - this is just what the Management Node calls itself."
  type        = string
  default     = "pexip.local"
}

variable "dns_servers" {
  description = <<-EOT
    DNS server IPs the Manager and Conferencing Nodes will use at runtime.
    The Manager gets these baked into its bootstrap config; Conf Nodes
    inherit from the system_location they belong to (register-conf-nodes.sh
    registers these as dns_server resources and attaches them).

    Without working DNS, conf nodes can still join the Pexip cluster but
    their outbound capabilities (Teams/Meet integration, NTP, SIP DNS
    SRV lookups, etc) silently fail. 8.8.8.8 covers the demo case.
  EOT
  type        = list(string)
  default     = ["8.8.8.8"]
}

variable "ntp_servers" {
  description = "NTP server hostnames/IPs for clock sync on all nodes. Same propagation pattern as dns_servers - Manager via bootstrap, Conf Nodes via system_location."
  type        = list(string)
  default     = ["pool.ntp.org"]
}

# ----------------------------------------------------------------------------
# Pexip image source (copied from Pexip's public project)
# ----------------------------------------------------------------------------

variable "pexip_source_image_project" {
  description = "GCP project that hosts the published Pexip images."
  type        = string
  default     = "pexip-product-images"
}

variable "pexip_management_source_image" {
  description = "Source image name for the Management Node in pexip_source_image_project."
  type        = string
}

variable "pexip_conferencing_source_image" {
  description = "Source image name for the Conferencing Node in pexip_source_image_project."
  type        = string
}

# ----------------------------------------------------------------------------
# TLS / ACME (optional)
#
# By default this stack ships self-signed certs (browser warning, but TLS
# is still TLS). Set enable_acme=true to obtain real Let's Encrypt certs
# via Cloudflare DNS-01 and push them into Pexip's TLS keystore via the
# Management API.
#
# IMPORTANT: starts in Let's Encrypt's STAGING environment. The resulting
# cert is NOT trusted by browsers (its root isn't in the trust store), but
# the issuance pipeline is identical to production. Flip
# acme_use_production=true once you've verified one full deploy works.
# Let's Encrypt's production rate limits (5 duplicate certs/domain/week,
# 5 failed validations/hour) are easy to burn through during iteration.
# ----------------------------------------------------------------------------

variable "enable_acme" {
  description = <<-EOT
    Issue real TLS certs via Let's Encrypt + Cloudflare DNS-01 and install
    them on the Manager + Conferencing Nodes. When false (default) the
    deployment uses self-signed certs and you'll get a browser warning.

    Requires acme_email, acme_domain, and cloudflare_api_token to also be
    set. The Cloudflare token needs Zone.DNS:Edit on the zone hosting
    acme_domain.
  EOT
  type        = bool
  default     = false
}

variable "acme_use_production" {
  description = <<-EOT
    Use Let's Encrypt PRODUCTION when issuing certs. Defaults to false
    (staging environment) so you can iterate without burning prod rate
    limits. Staging certs are real LE certs but signed by a non-trusted
    root, so browsers still warn. Flip to true only after one full
    end-to-end deploy succeeds.
  EOT
  type        = bool
  default     = false
}

variable "acme_email" {
  description = "Contact email for the Let's Encrypt account. Used for renewal-failure notifications."
  type        = string
  default     = ""
}

variable "acme_domain" {
  description = <<-EOT
    Base DNS domain to issue certs under. e.g. "demo.example.com" gives
    the Manager FQDN pexip-mgr.demo.example.com and conf nodes
    pexip-conf-1.demo.example.com, pexip-conf-2.demo.example.com, ...
    (override the per-host prefixes with acme_manager_hostname /
    acme_conf_hostname_prefix). You must create A records for these
    hostnames pointing at the IPs terraform prints in its outputs; the
    DNS-01 challenge itself only needs the zone to be on Cloudflare,
    not the A records.
  EOT
  type        = string
  default     = ""
}

variable "acme_manager_hostname" {
  description = "Short hostname for the Manager under acme_domain. Default 'pexip-mgr'."
  type        = string
  default     = "pexip-mgr"
}

variable "acme_conf_hostname_prefix" {
  description = "Short-hostname prefix for Conferencing Nodes under acme_domain. Default 'pexip-conf'. Conf node N becomes <prefix>-N.<acme_domain>."
  type        = string
  default     = "pexip-conf"
}

variable "cloudflare_api_token" {
  description = <<-EOT
    Cloudflare API token used to answer the DNS-01 challenge. Needs
    Zone.DNS:Edit on the zone hosting acme_domain. Create at
    https://dash.cloudflare.com/profile/api-tokens. Keep this in
    terraform.tfvars (gitignored) or set via TF_VAR_cloudflare_api_token
    — never commit it.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "manage_dns_records" {
  description = "Automatically create DNS A and SRV records in Cloudflare if enable_acme is true."
  type        = bool
  default     = true
}

variable "cloudflare_zone_name" {
  description = "The zone name in Cloudflare. If blank, defaults to acme_domain. Required if acme_domain is a subdomain but the Cloudflare zone is the apex (e.g. example.com)."
  type        = string
  default     = ""
}
