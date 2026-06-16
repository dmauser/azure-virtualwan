module "gcp_onprem" {
  for_each = var.environments

  source = "./modules/gcp-onprem"

  project               = var.project
  region                = each.value.region
  zone                  = each.value.zone
  allowed_source_ranges = var.allowed_source_ranges

  gcp_onprem = {
    deploy_gcp    = true
    network_name  = each.value.network_name
    network_cidr  = each.value.network_cidr
    subnet_cidr   = each.value.subnet_cidr
    vm_private_ip = each.value.vm_private_ip
  }
}
