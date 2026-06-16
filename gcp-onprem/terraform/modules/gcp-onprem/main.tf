locals {
  base_name = var.gcp_onprem.network_name
}

# ---------------------------------------------------------------------------
# VPC network
# ---------------------------------------------------------------------------
resource "google_compute_network" "onprem" {
  project                 = var.project
  name                    = var.gcp_onprem.network_name
  auto_create_subnetworks = false
  mtu                     = 1460
  routing_mode            = "REGIONAL"
}

# ---------------------------------------------------------------------------
# Subnet
# ---------------------------------------------------------------------------
resource "google_compute_subnetwork" "onprem" {
  project       = var.project
  name          = "${local.base_name}-subnet"
  ip_cidr_range = var.gcp_onprem.subnet_cidr
  region        = var.region
  network       = google_compute_network.onprem.self_link
}

# ---------------------------------------------------------------------------
# Firewall — allow inbound from allowed_source_ranges to tagged VMs
# ---------------------------------------------------------------------------
resource "google_compute_firewall" "onprem_allow" {
  project       = var.project
  name          = "${local.base_name}-allow"
  network       = google_compute_network.onprem.self_link
  source_ranges = var.allowed_source_ranges
  target_tags   = ["${local.base_name}-vm"]

  allow { protocol = "tcp" }
  allow { protocol = "udp" }
  allow { protocol = "icmp" }
}

# ---------------------------------------------------------------------------
# VM — no public IP; access via Cloud IAP (SSH-over-IAP)
# Startup script installs common network troubleshooting tools.
# ---------------------------------------------------------------------------
resource "google_compute_instance" "onprem" {
  project      = var.project
  name         = "${local.base_name}-vm"
  machine_type = "e2-micro"
  zone         = var.zone
  tags         = ["${local.base_name}-vm"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.onprem.self_link
    network_ip = var.gcp_onprem.vm_private_ip
    # No access_config block → no ephemeral public IP; use IAP for SSH.
  }

  metadata = {
    startup-script = <<-EOT
      #!/bin/bash
      apt-get update -y
      apt-get install -y traceroute tcpdump net-tools dnsutils curl iputils-ping
    EOT
  }
}

# ---------------------------------------------------------------------------
# Cloud Router
# A Cloud Router that backs a PARTNER Interconnect attachment MUST use the
# Google-assigned local ASN 16550 — custom ASNs (e.g. 65xxx) are rejected with
# "must be assigned a local ASN of '16550'". This is fixed by GCP for Partner
# Interconnect, so the ASN is not configurable here.
# ---------------------------------------------------------------------------
resource "google_compute_router" "onprem" {
  project = var.project
  name    = "${local.base_name}-router"
  region  = var.region
  network = google_compute_network.onprem.self_link

  bgp {
    asn = 16550
  }
}

# ---------------------------------------------------------------------------
# Partner Interconnect attachment
# Google peer ASN is fixed at 16550 for Partner Interconnect.
# The pairing_key output must be supplied to the Megaport VXC configuration.
# ---------------------------------------------------------------------------
resource "google_compute_interconnect_attachment" "partner" {
  project                  = var.project
  name                     = "${local.base_name}-partner-attachment"
  region                   = var.region
  type                     = "PARTNER"
  edge_availability_domain = "AVAILABILITY_DOMAIN_1"
  router                   = google_compute_router.onprem.id
  admin_enabled            = true
}
