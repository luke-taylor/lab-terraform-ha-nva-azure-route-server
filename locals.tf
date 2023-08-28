locals {
  hub_address_prefix             = "10.0.0.0/24"
  hub_subnet_bastion_prefix      = "10.0.0.0/27"
  hub_subnet_vpn_prefix          = "10.0.0.32/27"
  hub_subnet_route_server_prefix = "10.0.0.192/26"
  hub_subnet_nva_public_prefix   = "10.0.0.64/28"
  hub_subnet_nva_private_prefix  = "10.0.0.128/28"

  spoke_001_address_prefix   = "10.0.1.0/24" # If the prefix length is changed here you will need to modify the spoke_001_wildcard_mask in main.tf
  spoke_001_subnet_vm_prefix = "10.0.1.16/28"

  spoke_002_address_prefix   = "10.0.2.0/24" # If the prefix length is changed here you will need to modify the spoke_001_wildcard_mask in main.tf
  spoke_002_subnet_vm_prefix = "10.0.2.16/28"

  on_premises_address_prefix   = "172.16.0.0/16"
  on_premises_subnet_vm_prefix = "172.16.1.0/24"

  vpn_shared_key = var.vm_password
}
