resource "azurerm_resource_group" "this" {
  name     = "rg-ha-nva-azure-route-server"
  location = var.location
}

resource "azurerm_marketplace_agreement" "csr" {
  publisher = "cisco"
  offer     = "cisco-csr-1000v"
  plan      = "16_12-byol"
}

resource "azurerm_virtual_network" "hub" {
  name                = "vnet-hub"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = [local.hub_address_prefix]
}

resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [local.hub_subnet_bastion_prefix]
}

resource "azurerm_public_ip" "bastion" {
  name                = "pip-bastion"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_bastion_host" "bastion" {
  name                = "bas-hub"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  ip_configuration {
    name                 = "configuration"
    subnet_id            = azurerm_subnet.bastion.id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }
}

module "vnet-gateway" {
  source  = "Azure/vnet-gateway/azurerm"
  version = "0.1.0"

  location                            = azurerm_resource_group.this.location
  name                                = "vpn-hub"
  sku                                 = "VpnGw1"
  subnet_address_prefix               = local.hub_subnet_vpn_prefix
  type                                = "Vpn"
  vpn_active_active_enabled           = true
  vpn_bgp_enabled                     = true
  virtual_network_name                = azurerm_virtual_network.hub.name
  virtual_network_resource_group_name = azurerm_resource_group.this.name
  ip_configurations = {
    "001" = {
      public_ip = {
        allocation_method = "Static"
        sku               = "Standard"
      }
    }
    "002" = {
      public_ip = {
        allocation_method = "Static"
        sku               = "Standard"
      }
    }
  }
  depends_on = [
    azurerm_subnet.bastion
  ]
}

resource "azurerm_virtual_network" "on-premises" {
  name                = "on-premises-network"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = [local.on_premises_address_prefix]
}

module "on-premises-csr" {
  source  = "luke-taylor/nva/azurerm"
  version = "0.1.11"

  admin_password = var.vm_password
  admin_username = var.vm_username
  image = {
    marketplace_image = true
    publisher_id      = azurerm_marketplace_agreement.csr.publisher
    product_id        = azurerm_marketplace_agreement.csr.offer
    plan_id           = azurerm_marketplace_agreement.csr.plan
    version           = "latest"
  }
  name                 = "on-premises-csr"
  size                 = "Standard_D3_v2"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.on-premises.name
  location             = azurerm_resource_group.this.location
  nva_config_input = templatefile("${path.module}/config.onpremises.tftpl", {
    gateway_public_ip_001  = module.vnet-gateway.public_ip_addresses["001"].ip_address
    gateway_public_ip_002  = module.vnet-gateway.public_ip_addresses["002"].ip_address
    gateway_private_ip_001 = module.vnet-gateway.virtual_network_gateway.bgp_settings.0.peering_addresses[0].default_addresses[0]
    gateway_private_ip_002 = module.vnet-gateway.virtual_network_gateway.bgp_settings.0.peering_addresses[1].default_addresses[0]
    on_premises_asn        = 65001
    authorization_key      = local.vpn_shared_key
    }
  )
  network_interfaces = {
    public = {
      name                       = "on-premises-csr-interface"
      primary_interface          = true
      public_ip_creation_enabled = true
      public_ip = {
        name              = "on-premises-csr-ip"
        allocation_method = "Static"
      }
      subnet = {
        address_prefixes = [local.on_premises_subnet_vm_prefix]
        name             = "on-premises-csr-subnet"
      }
    }
  }

  depends_on = [
    module.vnet-gateway,
  ]
}

resource "azurerm_local_network_gateway" "this" {
  name                = "lgw-on-premises"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  gateway_address     = module.on-premises-csr.public_ips.public.ip_address
  address_space       = azurerm_virtual_network.on-premises.address_space
  bgp_settings {
    asn                 = 65001
    bgp_peering_address = module.on-premises-csr.network_interfaces.public.private_ip_address
  }

  depends_on = [
    module.on-premises-csr,
  ]
}

resource "azurerm_virtual_network_gateway_connection" "this" {
  name                = "conn-on-premises"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  type                       = "IPsec"
  virtual_network_gateway_id = module.vnet-gateway.virtual_network_gateway.id
  local_network_gateway_id   = azurerm_local_network_gateway.this.id
  enable_bgp                 = true

  shared_key = local.vpn_shared_key

  depends_on = [
    module.vnet-gateway,
    module.on-premises-csr,
    azurerm_local_network_gateway.this,
  ]
}

module "spokes" {
  source  = "Azure/lz-vending/azurerm"
  version = "3.4.0"

  subscription_id         = data.azurerm_client_config.current.subscription_id
  location                = azurerm_resource_group.this.location
  virtual_network_enabled = true
  virtual_networks = {
    spoke-001 = {
      name                            = "vnet-spoke-001"
      address_space                   = [local.spoke_001_address_prefix]
      resource_group_name             = azurerm_resource_group.this.name
      resource_group_creation_enabled = false
      hub_peering_enabled             = true
      hub_network_resource_id         = azurerm_virtual_network.hub.id
    }
    spoke-002 = {
      name                            = "vnet-spoke-002"
      address_space                   = [local.spoke_002_address_prefix]
      resource_group_name             = azurerm_resource_group.this.name
      resource_group_creation_enabled = false
      hub_peering_enabled             = true
      hub_network_resource_id         = azurerm_virtual_network.hub.id
    }
  }

  depends_on = [
    module.vnet-gateway
  ]
}

module "spoke-001-vm" {
  source  = "luke-taylor/nva/azurerm"
  version = "0.1.11"

  admin_password = var.vm_password
  admin_username = var.vm_username

  image = {
    publisher_id = "canonical"
    product_id   = "0001-com-ubuntu-server-focal"
    plan_id      = "20_04-lts"
  }

  name                 = "vm-spoke-001"
  size                 = "Standard_D3_v2"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = basename(module.spokes.virtual_network_resource_ids.spoke-001)
  location             = azurerm_resource_group.this.location

  network_interfaces = {
    public = {
      primary_interface    = true
      enable_ip_forwarding = false
      subnet = {
        address_prefixes              = [local.spoke_001_subnet_vm_prefix]
        name                          = "sn-vm-spoke-001"
        nsg_creation_enabled          = true
        nsg_allow_ssh_inbound_enabled = true
      }
    }
  }

  depends_on = [
    module.spokes,
  ]
}

module "spoke-002-vm" {
  source  = "luke-taylor/nva/azurerm"
  version = "0.1.11"

  admin_password = var.vm_password
  admin_username = var.vm_username

  image = {
    publisher_id = "canonical"
    product_id   = "0001-com-ubuntu-server-focal"
    plan_id      = "20_04-lts"
  }

  name                 = "vm-spoke-002"
  size                 = "Standard_D3_v2"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = basename(module.spokes.virtual_network_resource_ids.spoke-002)
  location             = azurerm_resource_group.this.location

  network_interfaces = {
    public = {
      primary_interface    = true
      enable_ip_forwarding = false
      subnet = {
        address_prefixes              = [local.spoke_002_subnet_vm_prefix]
        name                          = "sn-vm-spoke-002"
        nsg_creation_enabled          = true
        nsg_allow_ssh_inbound_enabled = true
      }
    }
  }

  depends_on = [
    module.spokes,
  ]
}


module "hub-nva-001" {
  source  = "luke-taylor/nva/azurerm"
  version = "0.1.11"

  admin_password = var.vm_password
  admin_username = var.vm_username

  image = {
    marketplace_image = true
    publisher_id      = azurerm_marketplace_agreement.csr.publisher
    product_id        = azurerm_marketplace_agreement.csr.offer
    plan_id           = azurerm_marketplace_agreement.csr.plan
    version           = "latest"
  }

  name                 = "vm-hub-nva-001"
  size                 = "Standard_D3_v2"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.hub.name
  location             = azurerm_resource_group.this.location
  nva_config_input = templatefile("${path.root}/config.nva.tftpl", {
    nva_asn                        = 65002
    private_subnet_default_gateway = cidrhost(local.hub_subnet_nva_private_prefix, 1)
    route_server_address           = cidrhost(local.hub_subnet_route_server_prefix, 0)
    route_server_mask              = cidrnetmask(local.hub_subnet_route_server_prefix)
    route_server_primary_ip        = cidrhost(local.hub_subnet_route_server_prefix, 4)
    route_server_secondary_ip      = cidrhost(local.hub_subnet_route_server_prefix, 5)
    spoke_001_address              = cidrhost(local.spoke_001_address_prefix, 0)
    spoke_001_wildcard_mask        = "0.0.0.255"
    spoke_002_address              = cidrhost(local.spoke_002_address_prefix, 0)
    spoke_002_wildcard_mask        = "0.0.0.255"
  })

  network_interfaces = {
    public = {
      private_ip_address = cidrhost(local.hub_subnet_nva_public_prefix, 4)
      primary_interface  = true
      subnet = {
        address_prefixes = [local.hub_subnet_nva_public_prefix]
        name             = "sn-nva-public"
      }
    }
    private = {
      private_ip_address = cidrhost(local.hub_subnet_nva_private_prefix, 4)
      subnet = {
        address_prefixes = [local.hub_subnet_nva_private_prefix]
        name             = "sn-nva-private"
      }
    }
  }
  depends_on = [
    azurerm_subnet.bastion,
    module.vnet-gateway,
  ]
}


module "hub-nva-002" {
  source  = "luke-taylor/nva/azurerm"
  version = "0.1.11"

  admin_password = var.vm_password
  admin_username = var.vm_username

  image = {
    marketplace_image = true
    publisher_id      = azurerm_marketplace_agreement.csr.publisher
    product_id        = azurerm_marketplace_agreement.csr.offer
    plan_id           = azurerm_marketplace_agreement.csr.plan
    version           = "latest"
  }

  name                 = "vm-hub-nva-002"
  size                 = "Standard_D3_v2"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.hub.name
  location             = azurerm_resource_group.this.location
  nva_config_input = templatefile("${path.root}/config.nva.tftpl", {
    nva_asn                        = 65003
    private_subnet_default_gateway = cidrhost(local.hub_subnet_nva_private_prefix, 1)
    route_server_address           = cidrhost(local.hub_subnet_route_server_prefix, 0)
    route_server_mask              = cidrnetmask(local.hub_subnet_route_server_prefix)
    route_server_primary_ip        = cidrhost(local.hub_subnet_route_server_prefix, 4)
    route_server_secondary_ip      = cidrhost(local.hub_subnet_route_server_prefix, 5)
    spoke_001_address              = cidrhost(local.spoke_001_address_prefix, 0)
    spoke_001_wildcard_mask        = "0.0.0.255"
    spoke_002_address              = cidrhost(local.spoke_002_address_prefix, 0)
    spoke_002_wildcard_mask        = "0.0.0.255"
  })

  network_interfaces = {
    public = {
      private_ip_address = cidrhost(local.hub_subnet_nva_public_prefix, 5)
      primary_interface  = true
      subnet_id          = module.hub-nva-001.subnets.public.id
    }
    private = {
      private_ip_address = cidrhost(local.hub_subnet_nva_private_prefix, 5)
      subnet_id          = module.hub-nva-001.subnets.private.id
    }
  }

  depends_on = [
    azurerm_subnet.bastion,
    module.vnet-gateway,
    module.hub-nva-001,
  ]
}

resource "azurerm_subnet" "this" {
  name                 = "RouteServerSubnet"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [local.hub_subnet_route_server_prefix]

  depends_on = [
    azurerm_subnet.bastion,
    module.vnet-gateway,
    module.hub-nva-001,
  ]
}

resource "azurerm_public_ip" "this" {
  name                = "pip-route-server"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_route_server" "this" {
  name                             = "ars-hub"
  resource_group_name              = azurerm_resource_group.this.name
  location                         = azurerm_resource_group.this.location
  sku                              = "Standard"
  public_ip_address_id             = azurerm_public_ip.this.id
  subnet_id                        = azurerm_subnet.this.id
  branch_to_branch_traffic_enabled = true
}

resource "azurerm_route_server_bgp_connection" "nva-001" {
  name            = "nva-001-connection"
  route_server_id = azurerm_route_server.this.id
  peer_asn        = 65002
  peer_ip         = module.hub-nva-001.network_interfaces.private.private_ip_address
}

resource "azurerm_route_server_bgp_connection" "nva-002" {
  name            = "nva-002-connection"
  route_server_id = azurerm_route_server.this.id
  peer_asn        = 65003
  peer_ip         = module.hub-nva-002.network_interfaces.private.private_ip_address
}
