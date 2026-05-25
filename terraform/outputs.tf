output "management_admin_url" {
  description = "Pexip Management Node admin UI."
  value       = var.enable_acme ? "https://${local.acme_manager_fqdn}/admin/" : "https://${google_compute_address.manager_public.address}/admin/"
}

output "management_public_ip" {
  description = "Public IP of the Management Node."
  value       = google_compute_address.manager_public.address
}

output "conferencing_node_ips" {
  description = "Public IPs of the Conferencing Nodes (in deploy order). Empty if conf_nodes_public = false."
  value       = [for a in google_compute_address.conf_public : a.address]
}

output "conferencing_node_internal_ips" {
  description = "Internal IPs of the Conferencing Nodes (always populated)."
  value       = [for a in google_compute_address.conf_private : a.address]
}

output "tls_status" {
  description = "Which TLS cert this deployment is using. Read this before opening the admin UI - if it says STAGING you'll still see a browser warning."
  value = var.enable_acme ? (
    var.acme_use_production
      ? "Let's Encrypt PRODUCTION cert installed (trusted by browsers)"
      : "Let's Encrypt STAGING cert installed - UNTRUSTED by browsers. Set acme_use_production=true and re-apply once you've verified the pipeline works."
  ) : "Self-signed cert (default). Browsers will warn; accept the warning to proceed."
}

output "dns_records_required" {
  description = "A records you need to create when var.enable_acme is true and var.manage_dns_records is false. Empty list otherwise."
  value = var.enable_acme && !var.manage_dns_records ? concat(
    [
      {
        fqdn = local.acme_manager_fqdn
        ip   = google_compute_address.manager_public.address
        role = "Manager"
      }
    ],
    [
      for i in range(var.transcoding_node_count) : {
        fqdn = local.acme_conf_fqdns[i]
        ip   = var.conf_nodes_public ? google_compute_address.conf_public[i].address : google_compute_address.conf_private[i].address
        role = "Conferencing Node ${i + 1}"
      }
    ]
  ) : []
}

output "connection_info" {
  description = "What to do next."
  sensitive   = true
  value       = <<-EOT

    ================================================================================
    Pexip Infinity is deployed and bootstrapped.
    ================================================================================

    %{if var.enable_acme~}
      TLS: Let's Encrypt ${local.acme_directory_label}
      %{if !var.acme_use_production~}
      *** STAGING CERT - browsers will still warn. The cert is real but its
      *** root isn't in any trust store. Flip acme_use_production=true and
      *** re-run `terraform apply` once you're happy with the deploy.
      %{endif~}

      Admin UI:   https://${local.acme_manager_fqdn}/admin/
                  (or https://${google_compute_address.manager_public.address}/admin/
                   if your DNS hasn't propagated yet)

      %{if var.manage_dns_records~}
      DNS records automatically created in Cloudflare:
        - A Record:    ${local.acme_manager_fqdn}  ->  ${google_compute_address.manager_public.address}
        %{for i in range(var.transcoding_node_count)~}
        - A Record:    ${local.acme_conf_fqdns[i]}  ->  ${var.conf_nodes_public ? google_compute_address.conf_public[i].address : google_compute_address.conf_private[i].address}
        %{endfor~}
        - SRV Record:  _sips._tcp.${var.acme_domain} (SIP TLS on port 5061)
        - SRV Record:  _sip._tcp.${var.acme_domain} (SIP TCP on port 5060)
        - SRV Record:  _pexapp._tcp.${var.acme_domain} (Pexip App on port 443)
      %{else~}
      DNS records you must have in place:
        - ${local.acme_manager_fqdn}  ->  ${google_compute_address.manager_public.address}
        %{for i in range(var.transcoding_node_count)~}
        - ${local.acme_conf_fqdns[i]}  ->  ${var.conf_nodes_public ? google_compute_address.conf_public[i].address : google_compute_address.conf_private[i].address}
        %{endfor~}
      %{endif~}
    %{else~}
      TLS: Self-signed (default)

      Admin UI:   https://${google_compute_address.manager_public.address}/admin/

      Open the admin UI, accept the self-signed certificate, and log in.
    %{endif~}

      Username:   admin
      Password:   (the pexip_admin_password you set in terraform.tfvars)

    Conferencing Nodes are pre-registered and will sync over the next few
    minutes (check Platform > Conferencing Nodes in the admin UI).

    %{if var.conf_nodes_public~}
      Conferencing Node public IPs:
    %{for ip in google_compute_address.conf_public.*.address~}
        - ${ip}
    %{endfor~}
    %{else~}
      Conferencing Nodes are INTERNAL ONLY (var.conf_nodes_public = false).
      Reach them via Cloud VPN / IAP / VPC peering on these internal IPs:
    %{for ip in google_compute_address.conf_private.*.address~}
        - ${ip}
    %{endfor~}
    %{endif~}

    To finish setup:
      1. Apply your Pexip license under Platform > Licenses.
      2. Configure a conference (Service Configuration > Virtual Meeting Rooms).

    Tear it all down when finished:
      ./scripts/destroy.sh
    ================================================================================
  EOT
}
