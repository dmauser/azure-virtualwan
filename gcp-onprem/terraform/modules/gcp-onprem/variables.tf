variable "project" {
  type        = string
  description = "GCP project ID."
}

variable "region" {
  type        = string
  description = "GCP region for all regional resources (subnet, router, attachment)."
}

variable "zone" {
  type        = string
  description = "GCP zone for the VM instance."
}

variable "gcp_onprem" {
  type = object({
    deploy_gcp       = bool
    network_name     = string
    network_cidr     = string
    subnet_cidr      = string
    vm_private_ip    = string
    cloud_router_asn = number
  })
  description = "Configuration object for this on-prem simulation environment."

  validation {
    condition     = can(cidrnetmask(var.gcp_onprem.subnet_cidr))
    error_message = "gcp_onprem.subnet_cidr must be a valid CIDR block."
  }

  validation {
    condition     = can(cidrnetmask(var.gcp_onprem.network_cidr))
    error_message = "gcp_onprem.network_cidr must be a valid CIDR block."
  }
}

variable "allowed_source_ranges" {
  type        = list(string)
  description = "CIDR ranges allowed by the VPC firewall rule. Must include IAP range 35.235.240.0/20."
  default = [
    "192.168.0.0/16",
    "10.0.0.0/8",
    "172.16.0.0/12",
    "35.235.240.0/20",
  ]

  validation {
    condition = alltrue([
      for r in var.allowed_source_ranges : can(cidrnetmask(r))
    ])
    error_message = "All entries in allowed_source_ranges must be valid CIDR blocks."
  }

  validation {
    condition     = contains(var.allowed_source_ranges, "35.235.240.0/20")
    error_message = "allowed_source_ranges must include the IAP range 35.235.240.0/20 to allow SSH-over-IAP."
  }
}
