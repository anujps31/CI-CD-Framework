provider "azurerm" {
  # AzureRM uses the pipeline or local Azure CLI identity for Azure operations.
  features {
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }
  # Inject subscription and tenant IDs from the pipeline identity or tfvars.
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
  use_cli         = true
  storage_use_azuread = true
  skip_provider_registration = true 
}

provider "azuread" {
  # AzureAD uses the same tenant context to manage Dev users, groups, and memberships.
  tenant_id = var.tenant_id
}

provider "databricks" {
  # This provider manages workspace-level Databricks objects after the workspace exists.
  host                        = var.databricks_host
  azure_workspace_resource_id = try(azurerm_databricks_workspace.dev[0].id, null)
}

provider "databricks" {
  alias = "account"
  # The account provider is used for Unity Catalog metastore administration.
  host                        = "https://accounts.azuredatabricks.net"
  account_id                  = var.databricks_account_id
  azure_client_id             = var.databricks_client_id
  azure_client_secret         = var.databricks_client_secret
  azure_workspace_resource_id = try(azurerm_databricks_workspace.dev[0].id, null)
}
