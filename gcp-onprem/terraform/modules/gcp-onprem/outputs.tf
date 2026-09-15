output "network_self_link" {
  description = "Self-link of the VPC network."
  value       = google_compute_network.onprem.self_link
}

output "subnet_name" {
  description = "Name of the subnet."
  value       = google_compute_subnetwork.onprem.name
}

output "router_name" {
  description = "Name of the Cloud Router."
  value       = google_compute_router.onprem.name
}

output "attachment_name" {
  description = "Name of the Partner Interconnect attachment."
  value       = google_compute_interconnect_attachment.partner.name
}

output "pairing_key" {
  description = "Partner Interconnect pairing key. Supply this to Megaport when creating the VXC."
  sensitive   = true
  value       = google_compute_interconnect_attachment.partner.pairing_key
}

output "vm_private_ip" {
  description = "Private IP address assigned to the on-prem simulation VM."
  value       = google_compute_instance.onprem.network_interface[0].network_ip
}

output "region" {
  description = "Region in which the environment's regional resources are created."
  value       = var.region
}

output "zone" {
  description = "Zone in which the on-prem simulation VM is created."
  value       = var.zone
}

output "network_name" {
  description = "Name of the VPC network."
  value       = google_compute_network.onprem.name
}

output "vm_name" {
  description = "Name of the on-prem simulation VM instance."
  value       = google_compute_instance.onprem.name
}

output "firewall_name" {
  description = "Name of the ingress firewall rule."
  value       = google_compute_firewall.onprem_allow.name
}
