variable "project" {
  type        = string
  description = "GCP project ID in which all resources are created."
}

variable "default_region" {
  type        = string
  description = "Default provider region. Typically set to the region of env1."
  default     = "us-west2"
}

variable "environments" {
  type = map(object({
    region        = string
    zone          = string
    network_name  = string
    network_cidr  = string
    subnet_cidr   = string
    vm_private_ip = string
  }))
  description = "Map of on-prem simulation environments. Keys are env1 / env2 (or any label)."

  validation {
    condition = alltrue([
      for k, v in var.environments :
      can(cidrnetmask(v.subnet_cidr))
    ])
    error_message = "Each environment's subnet_cidr must be a valid CIDR block."
  }

  validation {
    condition = alltrue([
      for k, v in var.environments :
      can(cidrnetmask(v.network_cidr))
    ])
    error_message = "Each environment's network_cidr must be a valid CIDR block."
  }
}

variable "allowed_source_ranges" {
  type        = list(string)
  description = "CIDR ranges allowed by the VPC firewall rule. Must include IAP range 35.235.240.0/20 for SSH-over-IAP."
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
