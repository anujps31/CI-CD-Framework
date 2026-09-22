resource "azuread_group" "dev" {
  # Stable Dev groups provide the access boundary for Azure and Databricks permissions.
  for_each         = var.manage_access_control ? toset(["platform-admins", "data-engineers", "readers"]) : toset([])
  display_name     = "grp-dataplatform-dev-${each.key}"
  security_enabled = true
  owners           = var.dev_admin_object_ids
}

resource "azuread_user" "dev" {
  # Optional test users are created only when explicitly supplied through Terraform input.
  for_each              = var.manage_access_control ? toset(nonsensitive(keys(var.dev_user_definitions))) : toset([])
  user_principal_name   = var.dev_user_definitions[each.key].user_principal_name
  display_name          = var.dev_user_definitions[each.key].display_name
  mail_nickname         = var.dev_user_definitions[each.key].mail_nickname
  password              = try(var.dev_user_definitions[each.key].password, null)
  force_password_change = true
}

locals {
  # Membership keys make later additions and removals predictable and non-destructive.
  dev_group_members = {
  platform-admins = var.dev_admin_object_ids
  data-engineers  = setunion(
    var.dev_data_engineer_object_ids,
    length(var.dev_user_definitions) > 0 ? toset([for user in azuread_user.dev : user.object_id]) : toset([])
  )
  readers = lookup(var.dev_group_members, "readers", [])
}
  dev_memberships = {
  for membership in flatten([
    for group_name, member_ids in local.dev_group_members : [
      for member_id in member_ids : {
        key       = "${group_name}-${nonsensitive(member_id)}"
        group     = group_name
        member_id = member_id
      }
    ]
  ]) : membership.key => membership
}
}

resource "azuread_group_member" "dev" {
  # Terraform reconciles the declared object IDs with the corresponding Dev groups.
  for_each         = var.manage_access_control ? nonsensitive(local.dev_memberships) : {}
  group_object_id  = azuread_group.dev[each.value.group].object_id
  member_object_id = each.value.member_id
}

resource "azurerm_role_assignment" "dev_platform_admins" {
    count                = var.manage_access_control ? 1 : 0
  # Platform administrators receive the Dev resource-group role through group membership.
  scope                = data.azurerm_resource_group.dev.id
  role_definition_name = "Contributor"
  principal_id         = azuread_group.dev["platform-admins"].object_id
}

resource "azurerm_role_assignment" "dev_data_engineers_reader" {
  count                = var.manage_access_control ? 1 : 0
  scope                = data.azurerm_resource_group.dev.id
  role_definition_name = "Reader"
  principal_id         = azuread_group.dev["data-engineers"].object_id
}

resource "azurerm_role_assignment" "dev_data_engineers_storage" {
  count                = var.manage_access_control ? 1 : 0
  scope                = azurerm_storage_account.dev.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azuread_group.dev["data-engineers"].object_id
}

resource "databricks_group" "dev_data_engineers" {
  count = var.enable_databricks && var.manage_access_control && var.enable_unity_catalog ? 1 : 0
  display_name = azuread_group.dev["data-engineers"].display_name
}

resource "databricks_group" "dev_readers" {
  count = var.enable_databricks && var.manage_access_control && var.enable_unity_catalog ? 1 : 0
  display_name = azuread_group.dev["readers"].display_name
}

resource "databricks_group" "account_data_engineers" {
  count        = var.enable_databricks && var.manage_access_control && var.enable_unity_catalog ? 1 : 0
  provider     = databricks.account
  display_name = azuread_group.dev["data-engineers"].display_name
}

resource "databricks_group" "account_readers" {
  count        = var.enable_databricks && var.manage_access_control && var.enable_unity_catalog ? 1 : 0
  provider     = databricks.account
  display_name = azuread_group.dev["readers"].display_name
}

resource "azurerm_role_assignment" "databricks_firstparty_keyvault" {
  count                = var.enable_databricks && var.databricks_firstparty_sp_object_id != null ? 1 : 0
  scope                = azurerm_key_vault.dev.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = var.databricks_firstparty_sp_object_id
}
