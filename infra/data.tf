resource "azurerm_storage_account" "dev" {
  # ADLS Gen2 is the private landing and curated data store for the Dev notebooks.
  name                              = "stdataplatformsyrendev01"
  resource_group_name               = data.azurerm_resource_group.dev.name
  location                          = var.location
  account_tier                      = "Standard"
  account_replication_type          = "LRS"
  account_kind                      = "StorageV2"
  is_hns_enabled                    = true
  min_tls_version                   = "TLS1_2"
  public_network_access_enabled     = false
  shared_access_key_enabled         = false
  default_to_oauth_authentication   = true
  infrastructure_encryption_enabled = true
  identity {
    type = "SystemAssigned"
  }
  blob_properties {
    versioning_enabled = false
    delete_retention_policy { days = 7 }
    container_delete_retention_policy { days = 7 }
  }
  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }
  tags = local.tags
}

resource "azurerm_storage_data_lake_gen2_filesystem" "raw" {
  # Raw data is kept separate from transformed data for clear pipeline boundaries.
  name               = "raw"
  storage_account_id = azurerm_storage_account.dev.id
}

resource "azurerm_storage_data_lake_gen2_filesystem" "silver" {
  # Silver data contains the transformed output used by downstream workloads.
  name               = "silver"
  storage_account_id = azurerm_storage_account.dev.id
}

resource "azurerm_databricks_access_connector" "dev" {
  # The access connector gives Databricks an Azure identity without storage keys.
  count               = var.enable_databricks ? 1 : 0
  name                = "dac-${local.name_prefix}"
  resource_group_name = data.azurerm_resource_group.dev.name
  location            = var.location
  identity { type = "SystemAssigned" }
  tags = local.tags
}

resource "azurerm_role_assignment" "databricks_storage_blob_contributor" {
  count                = var.enable_databricks && var.manage_access_control ? 1 : 0
  scope                = azurerm_storage_account.dev.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_databricks_access_connector.dev[0].identity[0].principal_id
}

resource "azurerm_role_assignment" "adf_storage_blob_contributor" {
  count                = var.manage_access_control ? 1 : 0
  scope                = azurerm_storage_account.dev.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_data_factory.dev.identity[0].principal_id
}
