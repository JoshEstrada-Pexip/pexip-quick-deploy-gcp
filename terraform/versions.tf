terraform {
  required_version = ">= 1.0.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0.0"
    }
    external = {
      source  = "hashicorp/external"
      version = ">= 2.0.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.0.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0.0"
    }
    acme = {
      source  = "vancluever/acme"
      version = ">= 2.0.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = ">= 4.0.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Let's Encrypt directory URL is selected at apply time. Staging by default
# (much higher rate limits, browser-untrusted cert) - flip with
# var.acme_use_production once the pipeline is verified end-to-end.
provider "acme" {
  server_url = var.acme_use_production ? "https://acme-v02.api.letsencrypt.org/directory" : "https://acme-staging-v02.api.letsencrypt.org/directory"
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token != "" ? trimspace(var.cloudflare_api_token) : null
}
