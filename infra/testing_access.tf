# Temporary access for the data testing team (requested by Ashok). Everything in this file
# exists only while enable_testing_access = true. To remove it, set the flag to false and apply
# from a workstation: the pipeline's delete gate blocks deletions by design.

locals {
  testing_access = var.enable_testing_access && var.enable_databricks && var.enable_unity_catalog
}

# Interactive (all-purpose) cluster with the same runtime and node size as the bundle job.
# Standard (shared) access mode, because a whole group uses it; the job uses single-user mode.
resource "databricks_cluster" "testing" {
  count                   = local.testing_access ? 1 : 0
  cluster_name            = "${local.name_prefix}-testing"
  spark_version           = "15.4.x-scala2.12"
  node_type_id            = "Standard_DS3_v2"
  data_security_mode      = "USER_ISOLATION"
  autotermination_minutes = 20   # Stops the cluster after 20 idle minutes, so cost stops too.
  no_wait                 = true # Don't make the pipeline wait for the cluster to start.

  autoscale {
    min_workers = 1
    max_workers = 2
  }

  custom_tags = {
    Purpose = "testing"
    Owner   = "data-testing"
  }
}

resource "databricks_permissions" "testing_cluster" {
  count      = local.testing_access ? 1 : 0
  cluster_id = databricks_cluster.testing[0].id

  access_control {
    group_name       = var.testing_group_name
    permission_level = "CAN_MANAGE"
  }
}

# databricks_grant (singular) manages only this group's privileges and leaves every other grant
# on the object untouched. databricks_grants (plural) would remove all unlisted grants.
resource "databricks_grant" "testing_catalog" {
  count      = local.testing_access ? 1 : 0
  catalog    = databricks_catalog.dev[0].name
  principal  = var.testing_group_name
  privileges = ["USE_CATALOG", "BROWSE", "READ_VOLUME"]
}

resource "databricks_grant" "testing_schema" {
  for_each = local.testing_access ? {
    raw    = databricks_schema.raw[0].id
    silver = databricks_schema.silver[0].id
  } : {}
  schema     = each.value
  principal  = var.testing_group_name
  privileges = ["USE_SCHEMA", "SELECT", "EXECUTE", "READ_VOLUME", "MANAGE", "CREATE_FUNCTION", "CREATE_TABLE"]
}

# Broad on purpose "for now": the credential reaches the whole storage account, so ALL PRIVILEGES
# lets the group create external locations anywhere in it. Long term, grant READ FILES /
# CREATE EXTERNAL TABLE on the external location dataplatform-dev-raw instead.
resource "databricks_grant" "testing_storage_credential" {
  count              = local.testing_access ? 1 : 0
  storage_credential = databricks_storage_credential.dev[0].id
  principal          = var.testing_group_name
  privileges         = ["ALL_PRIVILEGES"]
}