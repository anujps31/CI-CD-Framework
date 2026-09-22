resource "azurerm_virtual_network" "dev" {
  # All private Dev services share this isolated address space.
  name                = "vnet-${local.name_prefix}"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.dev.name
  address_space       = ["10.20.0.0/16"]
  tags                = local.tags
}

resource "azurerm_network_security_group" "databricks" {
  # Databricks subnets use a dedicated NSG for control-plane traffic rules.
  name                = "nsg-${local.name_prefix}-databricks"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.dev.name
  tags                = local.tags
}

resource "azurerm_network_security_group" "private_endpoints" {
  # Private endpoint traffic is restricted to the internal network and HTTPS.
  name                = "nsg-${local.name_prefix}-private-endpoints"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.dev.name
  tags                = local.tags
}

resource "azurerm_network_security_group" "aks" {
  # AKS receives its own NSG so workload network rules can evolve independently.
  count               = var.enable_microservices ? 1 : 0
  name                = "nsg-${local.name_prefix}-aks"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.dev.name
  tags                = local.tags
}

resource "azurerm_network_security_rule" "private_endpoints_https" {
  name                        = "allow-vnet-https"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "VirtualNetwork"
  resource_group_name         = data.azurerm_resource_group.dev.name
  network_security_group_name = azurerm_network_security_group.private_endpoints.name
}

resource "azurerm_network_security_rule" "private_endpoints_internet" {
  name                        = "deny-internet-inbound"
  priority                    = 4096
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = data.azurerm_resource_group.dev.name
  network_security_group_name = azurerm_network_security_group.private_endpoints.name
}

resource "azurerm_network_security_rule" "databricks_control_plane" {
  name                        = "allow-azure-control-plane-https"
  priority                    = 104
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "AzureCloud"
  resource_group_name         = data.azurerm_resource_group.dev.name
  network_security_group_name = azurerm_network_security_group.databricks.name
}

resource "azurerm_network_security_rule" "databricks_deny_internet" {
  name                        = "deny-internet-inbound"
  priority                    = 4096
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = data.azurerm_resource_group.dev.name
  network_security_group_name = azurerm_network_security_group.databricks.name
}

resource "azurerm_subnet" "databricks_public" {
  # This Databricks delegated subnet hosts the workspace public-side infrastructure without public IPs.
  name                 = "snet-databricks-public"
  resource_group_name  = data.azurerm_resource_group.dev.name
  virtual_network_name = azurerm_virtual_network.dev.name
  address_prefixes     = ["10.20.1.0/24"]
  delegation {
    name = "databricks"
    service_delegation {
      name    = "Microsoft.Databricks/workspaces"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action", "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action", "Microsoft.Network/virtualNetworks/subnets/unprepareNetworkPolicies/action"]
    }
  }
}

resource "azurerm_subnet" "databricks_private" {
  # This delegated subnet hosts Databricks private compute interfaces.
  name                 = "snet-databricks-private"
  resource_group_name  = data.azurerm_resource_group.dev.name
  virtual_network_name = azurerm_virtual_network.dev.name
  address_prefixes     = ["10.20.2.0/24"]
  delegation {
    name = "databricks"
    service_delegation {
      name    = "Microsoft.Databricks/workspaces"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action", "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action", "Microsoft.Network/virtualNetworks/subnets/unprepareNetworkPolicies/action"]
    }
  }
}

resource "azurerm_subnet" "private_endpoints" {
  # All private service endpoints are placed in one dedicated subnet.
  name                              = "snet-private-endpoints"
  resource_group_name               = data.azurerm_resource_group.dev.name
  virtual_network_name              = azurerm_virtual_network.dev.name
  address_prefixes                  = ["10.20.10.0/24"]
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_subnet" "aks" {
  # AKS nodes use a separate subnet from Databricks and private endpoints.
  count                = var.enable_microservices ? 1 : 0
  name                 = "snet-aks"
  resource_group_name  = data.azurerm_resource_group.dev.name
  virtual_network_name = azurerm_virtual_network.dev.name
  address_prefixes     = ["10.20.20.0/22"]
}

resource "azurerm_network_security_group" "azdo_runner" {
  count               = var.enable_azdo_runner_vm ? 1 : 0
  name                = "nsg-${local.name_prefix}-azdo-runner-01"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.dev.name
  tags                = local.tags
}

resource "azurerm_network_security_rule" "azdo_runner_ssh" {
  count                       = var.enable_azdo_runner_vm ? 1 : 0
  name                        = "allow-vnet-ssh"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "VirtualNetwork"
  resource_group_name         = data.azurerm_resource_group.dev.name
  network_security_group_name = azurerm_network_security_group.azdo_runner[0].name
}

resource "azurerm_subnet" "azdo_runner" {
  count                = var.enable_azdo_runner_vm ? 1 : 0
  name                 = "snet-azdo-runner-01"
  resource_group_name  = data.azurerm_resource_group.dev.name
  virtual_network_name = azurerm_virtual_network.dev.name
  address_prefixes     = ["10.20.24.0/24"]
}

resource "azurerm_subnet_network_security_group_association" "azdo_runner" {
  count                     = var.enable_azdo_runner_vm ? 1 : 0
  subnet_id                 = azurerm_subnet.azdo_runner[0].id
  network_security_group_id = azurerm_network_security_group.azdo_runner[0].id
}

resource "azurerm_subnet_network_security_group_association" "databricks_public" {
  subnet_id                 = azurerm_subnet.databricks_public.id
  network_security_group_id = azurerm_network_security_group.databricks.id
}

resource "azurerm_subnet_network_security_group_association" "databricks_private" {
  subnet_id                 = azurerm_subnet.databricks_private.id
  network_security_group_id = azurerm_network_security_group.databricks.id
}

resource "azurerm_subnet_network_security_group_association" "private_endpoints" {
  subnet_id                 = azurerm_subnet.private_endpoints.id
  network_security_group_id = azurerm_network_security_group.private_endpoints.id
}

resource "azurerm_subnet_network_security_group_association" "aks" {
  count                     = var.enable_microservices ? 1 : 0
  subnet_id                 = azurerm_subnet.aks[0].id
  network_security_group_id = azurerm_network_security_group.aks[0].id
}

resource "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = data.azurerm_resource_group.dev.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone" "dfs" {
  name                = "privatelink.dfs.core.windows.net"
  resource_group_name = data.azurerm_resource_group.dev.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone" "key_vault" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = data.azurerm_resource_group.dev.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone" "acr" {
  count               = var.enable_microservices ? 1 : 0
  name                = "privatelink.azurecr.io"
  resource_group_name = data.azurerm_resource_group.dev.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone" "data_factory" {
  name                = "privatelink.datafactory.azure.net"
  resource_group_name = data.azurerm_resource_group.dev.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone" "databricks" {
  name                = "privatelink.azuredatabricks.net"
  resource_group_name = data.azurerm_resource_group.dev.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "dev" {
  # These links make private service names resolve correctly inside the Dev VNet.
  for_each = merge({
    blob         = azurerm_private_dns_zone.blob
    dfs          = azurerm_private_dns_zone.dfs
    key_vault    = azurerm_private_dns_zone.key_vault
    data_factory = azurerm_private_dns_zone.data_factory
    databricks   = azurerm_private_dns_zone.databricks
  }, var.enable_microservices ? { acr = azurerm_private_dns_zone.acr[0] } : {})
  name                  = "link-${each.key}-${local.name_prefix}"
  resource_group_name   = data.azurerm_resource_group.dev.name
  private_dns_zone_name = each.value.name
  virtual_network_id    = azurerm_virtual_network.dev.id
  registration_enabled  = false
}

resource "azurerm_private_endpoint" "storage_blob" {
  # Blob access uses the Storage private endpoint rather than the public endpoint.
  name                = "pe-${local.name_prefix}-blob"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.dev.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  private_service_connection {
    name                           = "psc-${local.name_prefix}-blob"
    private_connection_resource_id = azurerm_storage_account.dev.id
    is_manual_connection           = false
    subresource_names              = ["blob"]
  }
  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob.id]
  }
}

resource "azurerm_private_endpoint" "storage_dfs" {
  name                = "pe-${local.name_prefix}-dfs"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.dev.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  private_service_connection {
    name                           = "psc-${local.name_prefix}-dfs"
    private_connection_resource_id = azurerm_storage_account.dev.id
    is_manual_connection           = false
    subresource_names              = ["dfs"]
  }
  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.dfs.id]
  }
}

resource "azurerm_private_endpoint" "key_vault" {
  name                = "pe-${local.name_prefix}-keyvault"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.dev.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  private_service_connection {
    name                           = "psc-${local.name_prefix}-keyvault"
    private_connection_resource_id = azurerm_key_vault.dev.id
    is_manual_connection           = false
    subresource_names              = ["vault"]
  }
  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.key_vault.id]
  }
}

resource "azurerm_private_endpoint" "acr" {
  count               = var.enable_microservices ? 1 : 0
  name                = "pe-${local.name_prefix}-acr"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.dev.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  private_service_connection {
    name                           = "psc-${local.name_prefix}-acr"
    private_connection_resource_id = azurerm_container_registry.dev[0].id
    is_manual_connection           = false
    subresource_names              = ["registry"]
  }
  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.acr[0].id]
  }
}

resource "azurerm_private_endpoint" "data_factory" {
  name                = "pe-${local.name_prefix}-adf"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.dev.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  private_service_connection {
    name                           = "psc-${local.name_prefix}-adf"
    private_connection_resource_id = azurerm_data_factory.dev.id
    is_manual_connection           = false
    subresource_names              = ["dataFactory"]
  }
  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.data_factory.id]
  }
}

resource "azurerm_private_endpoint" "databricks" {
  count               = var.enable_databricks ? 1 : 0
  name                = "pe-${local.name_prefix}-databricks"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.dev.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  private_service_connection {
    name                           = "psc-${local.name_prefix}-databricks"
    private_connection_resource_id = azurerm_databricks_workspace.dev[0].id
    is_manual_connection           = false
    subresource_names              = ["databricks_ui_api"]
  }
  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.databricks.id]
  }
}
