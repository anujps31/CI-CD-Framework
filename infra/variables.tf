variable "project_name" {
  # This prefix keeps names consistent across all Dev resources.
  type    = string
  default = "dataplatform"
}
variable "environment" {
  type    = string
  default = "dev"
  # Keep this list aligned with infra/environments and pipeline stage names.
  validation {
    condition     = var.environment == "dev"
    error_message = "This Terraform configuration currently supports the dev environment only."
  }
}
variable "location" {
  type = string
  # Change per environment only when the Azure region is intentionally different.
  default = "eastus"
}
variable "resource_group_name" {
  type        = string
  description = "Existing resource group that owns the Dev platform resources."
  default     = "NA_ResourceRG"
}
variable "subscription_id" {
  type    = string
  default = null
}
variable "tenant_id" {
  type    = string
  default = null
}
variable "databricks_host" {
  type        = string
  description = "Workspace URL for the Dev Databricks provider."
  default     = null
}
variable "databricks_account_id" {
  type        = string
  description = "Databricks account ID used for Unity Catalog metastore management."
  default     = null
}
variable "databricks_client_id" {
  type        = string
  description = "Entra application ID used by the Databricks account provider."
  default     = null
  sensitive   = true
}
variable "databricks_client_secret" {
  type        = string
  description = "Secret for the Databricks account provider, supplied by the pipeline."
  default     = null
  sensitive   = true
}
variable "dev_admin_object_ids" {
  type        = set(string)
  description = "Existing Entra object IDs for Dev platform administrators."
  default     = []
}
variable "dev_data_engineer_object_ids" {
  type        = set(string)
  description = "Existing Entra object IDs for Dev data engineers."
  default     = []
}
variable "dev_user_definitions" {
  # Keep this sensitive map in a secret variable group when creating test users.
  type = map(object({
    user_principal_name = string
    display_name        = string
    mail_nickname       = string
    password            = optional(string)
  }))
  description = "Optional Dev-only users. Prefer existing enterprise identity lifecycle processes for human users."
  default     = {}
  sensitive   = true
}
variable "dev_group_members" {
  type        = map(set(string))
  description = "Additional Entra object IDs keyed by managed Dev group name. Membership is reconciled by Terraform for declared entries."
  default     = {}
}

variable "manage_access_control" {
  type        = bool
  description = "Manage Entra groups, Azure RBAC assignments, and Databricks group grants."
  default     = false
}

# DEFERRED: restore budget_alert_emails after Dev functional testing.
# variable "budget_alert_emails" {
#   type        = list(string)
#   description = "Dev budget alert recipients."
#   default     = []
# }
variable "enable_databricks" {
  type = bool
  # Set by the selected deployment profile in the pipeline.
  default = true
}
variable "enable_microservices" {
  type = bool
  # Set true for FULL_PLATFORM or MICROSERVICES_ONLY profiles.
  default = false
}
variable "enable_unity_catalog" {
  type        = bool
  description = "Provision Unity Catalog metastore, catalog, schemas, and grants. Requires workspace API reachability."
  default     = false
}
variable "databricks_metastore_id" {
  type    = string
  default = "65021344-aefd-42a7-8d1f-e35122926690"
}
variable "databricks_allowed_ip_ranges" {
  type        = list(string)
  description = "IP ranges allowed to reach the Databricks workspace UI/API."
  default     = []
}