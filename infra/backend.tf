terraform {
  # The Dev state is kept remotely so pipeline runs share one source of truth.
  required_version = ">= 1.7.0"
  backend "azurerm" {
    # Values are supplied by infra/environments/<env>/backend.tfvars during pipeline execution.
    use_azuread_auth = true
  }
  required_providers {
    # AzureRM manages Azure resources, AzureAD manages directory objects, and Databricks manages workspace governance.
    azurerm    = { source = "hashicorp/azurerm", version = "~> 3.100" }
    azuread    = { source = "hashicorp/azuread", version = "~> 2.47" }
    databricks = { source = "databricks/databricks", version = "~> 1.50" }
  }
}
