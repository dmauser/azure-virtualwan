output "pairing_keys" {
  description = "Partner Interconnect pairing keys per environment. Copy each key to your Megaport VXC."
  sensitive   = true
  value = {
    for k, mod in module.gcp_onprem :
    k => mod.pairing_key
  }
}

output "router_names" {
  description = "Cloud Router names per environment."
  value = {
    for k, mod in module.gcp_onprem :
    k => mod.router_name
  }
}

output "attachment_names" {
  description = "Interconnect attachment names per environment."
  value = {
    for k, mod in module.gcp_onprem :
    k => mod.attachment_name
  }
}

output "vm_private_ips" {
  description = "Private IP addresses of the on-prem simulation VMs."
  value = {
    for k, mod in module.gcp_onprem :
    k => mod.vm_private_ip
  }
}

output "network_self_links" {
  description = "Self-links of the VPC networks per environment."
  value = {
    for k, mod in module.gcp_onprem :
    k => mod.network_self_link
  }
}
