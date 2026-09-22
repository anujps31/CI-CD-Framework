locals {
  # All resource names are generated from the project and selected environment.
  name_prefix = "${var.project_name}-${var.environment}"
  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    Framework   = "plug-and-play-cicd"
    # DEFERRED: enable cost attribution after Dev functional testing.
    # CostCenter         = "dataplatform-dev"
    Owner = "data-platform"
    # DEFERRED: enable workload cost tagging after Dev functional testing.
    # Workload           = "demo-poc"
    DataClassification = "internal"
  }
}

data "azurerm_resource_group" "dev" {
  # The target resource group is owned outside this workload state.
  name = var.resource_group_name
}

resource "azurerm_key_vault" "dev" {
  # Key Vault is private and uses RBAC so secrets are accessed through identities.
  name                          = "kv-${substr(replace(local.name_prefix, "-", ""), 0, 20)}"
  location                      = var.location
  resource_group_name           = data.azurerm_resource_group.dev.name
  tenant_id                     = var.tenant_id
  sku_name                      = "standard"
  purge_protection_enabled      = true
  soft_delete_retention_days    = 90
  enable_rbac_authorization     = true
  public_network_access_enabled = false
  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }
  tags = local.tags
}

resource "azurerm_data_factory" "dev" {
  # ADF runs with a managed identity and managed virtual network for private integration.
  name                = "adf-dataplatform-syrendev01"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.dev.name
  identity { type = "SystemAssigned" }
  managed_virtual_network_enabled = true
  public_network_enabled          = false
  tags                            = local.tags
}

resource "azurerm_databricks_workspace" "dev" {
  # Databricks is deployed with Premium features required for Unity Catalog and private networking.
  # The pipeline disables dev resource for ADF_ONLY and MICROSERVICES_ONLY.
  count                                 = var.enable_databricks ? 1 : 0
  name                                  = "dbw-${local.name_prefix}"
  resource_group_name                   = data.azurerm_resource_group.dev.name
  location                              = var.location
  sku                                   = "premium"
  managed_resource_group_name           = "rg-${local.name_prefix}-dbw-managed"
  public_network_access_enabled         = true
  network_security_group_rules_required = "NoAzureDatabricksRules"
  custom_parameters {
    virtual_network_id                                   = azurerm_virtual_network.dev.id
    public_subnet_name                                   = azurerm_subnet.databricks_public.name
    private_subnet_name                                  = azurerm_subnet.databricks_private.name
    public_subnet_network_security_group_association_id  = azurerm_subnet_network_security_group_association.databricks_public.id
    private_subnet_network_security_group_association_id = azurerm_subnet_network_security_group_association.databricks_private.id
    no_public_ip                                         = true
  }
  tags = local.tags
}

resource "azurerm_container_registry" "dev" {
  # ACR is optional for the microservice profile and is private when enabled.
  # The pipeline enables ACR and AKS only for microservice profiles.
  count                         = var.enable_microservices ? 1 : 0
  name                          = "acrdataplatformsyrendev01"
  resource_group_name           = data.azurerm_resource_group.dev.name
  location                      = var.location
  sku                           = "Premium"
  admin_enabled                 = false
  public_network_access_enabled = false
  tags                          = local.tags
}

resource "azurerm_kubernetes_cluster" "dev" {
  # AKS is optional, private, and attached to the dedicated Dev VNet subnet.
  count                      = var.enable_microservices ? 1 : 0
  name                       = "aks-${local.name_prefix}"
  location                   = var.location
  resource_group_name        = data.azurerm_resource_group.dev.name
  dns_prefix                 = "aks-${replace(local.name_prefix, "-", "-")}"
  sku_tier                   = "Standard"
  private_cluster_enabled    = true
 # dns_prefix_private_cluster = "aks-${replace(local.name_prefix, "-", "")}-private"
  oidc_issuer_enabled        = true
  workload_identity_enabled  = true
  azure_policy_enabled       = true
  network_profile {
    network_plugin    = "azure"
    network_policy    = "azure"
    load_balancer_sku = "standard"
  }

  default_node_pool {
    name           = "system"
    node_count     = 1
    vm_size        = "Standard_D2s_v5"
    vnet_subnet_id = azurerm_subnet.aks[0].id
  }

  identity { type = "SystemAssigned" }
  tags = local.tags
}

resource "azurerm_role_assignment" "aks_acr_pull" {
  count                = var.enable_microservices ? 1 : 0
  scope                = azurerm_container_registry.dev[0].id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.dev[0].kubelet_identity[0].object_id
}

resource "azurerm_role_assignment" "adf_key_vault" {
  scope                = azurerm_key_vault.dev.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_data_factory.dev.identity[0].principal_id
}

resource "azurerm_network_interface" "azdo_runner" {
  count               = var.enable_azdo_runner_vm ? 1 : 0
  name                = "nic-${local.name_prefix}-azdo-runner-01"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.dev.name
  tags                = local.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.azdo_runner[0].id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "azdo_runner" {
  count                           = var.enable_azdo_runner_vm ? 1 : 0
  name                            = "vm-${local.name_prefix}-azdo-runner-01"
  location                        = var.location
  resource_group_name             = data.azurerm_resource_group.dev.name
  size                            = var.azdo_runner_vm_size
  admin_username                  = "azureagent"
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.azdo_runner[0].id]
  custom_data                     = filebase64("${path.module}/../scripts/self-hosted-agent-cloud-init.sh")
  identity { type = "SystemAssigned" }

  admin_ssh_key {
    username   = "azureagent"
    public_key = var.azdo_runner_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 64
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
  lifecycle {
    ignore_changes = [custom_data]
  }

  tags = local.tags
}

resource "azurerm_role_assignment" "azdo_runner_contributor" {
  count                = var.enable_azdo_runner_vm ? 1 : 0
  scope                = data.azurerm_resource_group.dev.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_linux_virtual_machine.azdo_runner[0].identity[0].principal_id
}

resource "azurerm_role_assignment" "azdo_runner_storage" {
  count                = var.enable_azdo_runner_vm ? 1 : 0
  scope                = azurerm_storage_account.dev.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_linux_virtual_machine.azdo_runner[0].identity[0].principal_id
}

resource "azurerm_role_assignment" "azdo_runner_keyvault" {
  count                = var.enable_azdo_runner_vm ? 1 : 0
  scope                = azurerm_key_vault.dev.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azurerm_linux_virtual_machine.azdo_runner[0].identity[0].principal_id
}

resource "azurerm_role_assignment" "azdo_runner_aks_user" {
  count                = var.enable_azdo_runner_vm && var.enable_microservices ? 1 : 0
  scope                = azurerm_kubernetes_cluster.dev[0].id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = azurerm_linux_virtual_machine.azdo_runner[0].identity[0].principal_id
}

resource "azurerm_role_assignment" "azdo_runner_acr_pull" {
  count                = var.enable_azdo_runner_vm && var.enable_microservices ? 1 : 0
  scope                = azurerm_container_registry.dev[0].id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_linux_virtual_machine.azdo_runner[0].identity[0].principal_id
}

output "resource_group_name" { value = data.azurerm_resource_group.dev.name }
output "key_vault_name" { value = azurerm_key_vault.dev.name }
output "adf_name" { value = azurerm_data_factory.dev.name }
output "databricks_workspace_url" { value = try(azurerm_databricks_workspace.dev[0].workspace_url, null) }
output "acr_name" { value = try(azurerm_container_registry.dev[0].name, null) }
output "aks_name" { value = try(azurerm_kubernetes_cluster.dev[0].name, null) }
output "azdo_runner_vm_name" { value = try(azurerm_linux_virtual_machine.azdo_runner[0].name, null) }
output "azdo_runner_private_ip" { value = try(azurerm_network_interface.azdo_runner[0].private_ip_address, null) }