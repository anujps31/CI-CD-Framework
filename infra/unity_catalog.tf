# resource "databricks_metastore" "dev" {
#   count = var.enable_databricks && var.enable_unity_catalog ? 1 : 0
#   # The Dev metastore is the account-level Unity Catalog control plane.
#   provider      = databricks.account
#   name          = "metastore-${local.name_prefix}"
#   region        = var.location
#   storage_root  = "abfss://${azurerm_storage_data_lake_gen2_filesystem.raw.name}@${azurerm_storage_account.dev.name}.dfs.core.windows.net/"
#   force_destroy = false
# }

# resource "databricks_metastore_assignment" "dev" {
#   count = var.enable_databricks && var.enable_unity_catalog ? 1 : 0
#   # Assign the new workspace to the Dev metastore before creating catalog objects.
#   provider     = databricks.account
#   workspace_id = azurerm_databricks_workspace.dev[0].workspace_id
#   metastore_id = databricks_metastore.dev[0].id
# }
resource "databricks_metastore_assignment" "dev" {
  count        = var.enable_databricks && var.enable_unity_catalog ? 1 : 0
  metastore_id = var.databricks_metastore_id
  workspace_id = azurerm_databricks_workspace.dev[0].workspace_id
  provider     = databricks.account
}

resource "databricks_storage_credential" "dev" {
  count = var.enable_databricks && var.enable_unity_catalog ? 1 : 0
  # Unity Catalog accesses ADLS through the Databricks access connector identity.
  name = "${local.name_prefix}-storage-credential"
  azure_managed_identity {
    access_connector_id = azurerm_databricks_access_connector.dev[0].id
  }
  comment = "Managed identity credential for the Dev ADLS Gen2 account."
}

resource "databricks_external_location" "raw" {
  count = var.enable_databricks && var.enable_unity_catalog ? 1 : 0
  # This governed location maps the raw ADLS filesystem into Unity Catalog.
  name            = "${local.name_prefix}-raw"
  url             = "abfss://${azurerm_storage_data_lake_gen2_filesystem.raw.name}@${azurerm_storage_account.dev.name}.dfs.core.windows.net/"
  credential_name = databricks_storage_credential.dev[0].name
  comment         = "Dev raw landing zone."
}

resource "databricks_catalog" "dev" {
  count = var.enable_databricks && var.enable_unity_catalog ? 1 : 0
  # The catalog separates Dev data objects from future environments.
  name         = "dataplatform_dev"
  storage_root = databricks_external_location.raw[0].url
  comment      = "Dev Unity Catalog catalog for demonstration and validation."
  depends_on   = [databricks_metastore_assignment.dev]
}

resource "databricks_schema" "raw" {
  count = var.enable_databricks && var.enable_unity_catalog ? 1 : 0
  catalog_name = databricks_catalog.dev[0].name
  name         = "raw"
  comment      = "Raw Dev data."
}

resource "databricks_schema" "silver" {
  count = var.enable_databricks && var.enable_unity_catalog ? 1 : 0
  catalog_name = databricks_catalog.dev[0].name
  name         = "silver"
  comment      = "Curated Dev data."
}

resource "databricks_grants" "catalog" {
  count   = var.enable_databricks && var.manage_access_control && var.enable_unity_catalog ? 1 : 0
  catalog = databricks_catalog.dev[0].name
  grant {
    principal  = databricks_group.account_data_engineers[0].display_name
    privileges = ["USE_CATALOG", "USE_SCHEMA", "CREATE_SCHEMA", "CREATE_TABLE", "MODIFY"]
  }
  grant {
    principal  = databricks_group.account_readers[0].display_name
    privileges = ["USE_CATALOG", "USE_SCHEMA", "SELECT"]
  }
}

resource "databricks_ip_access_list" "office_allow" {
  count        = var.enable_databricks && length(var.databricks_allowed_ip_ranges) > 0 ? 1 : 0
  label        = "anuj-allow"
  ip_addresses = var.databricks_allowed_ip_ranges
  list_type    = "ALLOW"
}

resource "databricks_secret_scope" "keyvault" {
  count = var.enable_databricks ? 1 : 0
  name  = "kv-${local.name_prefix}"

  keyvault_metadata {
    resource_id = azurerm_key_vault.dev.id
    dns_name    = azurerm_key_vault.dev.vault_uri
  }
}

output "dev_storage_account_name" {
  value = azurerm_storage_account.dev.name
}
