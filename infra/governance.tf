/* DEFERRED UNTIL DEV FUNCTIONAL TESTING IS COMPLETE:
  budgets, alerts, diagnostics, Log Analytics, and Databricks cost controls.
resource "azurerm_log_analytics_workspace" "dev" {
  name                = "law-${local.name_prefix}"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.dev.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  name                       = "diag-${local.name_prefix}-keyvault"
  target_resource_id         = azurerm_key_vault.dev.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.dev.id
  enabled_log { category = "AuditEvent" }
  metric { category = "AllMetrics" }
}

resource "azurerm_consumption_budget_resource_group" "dev" {
  name              = "budget-${local.name_prefix}"
  resource_group_id = data.azurerm_resource_group.dev.id
  amount            = 150
  time_grain        = "Monthly"
  time_period {
    start_date = "2026-09-01T00:00:00Z"
    end_date   = "2036-09-01T00:00:00Z"
  }
  notification {
    enabled        = true
    threshold      = 50
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = var.budget_alert_emails
  }
  notification {
    enabled        = true
    threshold      = 75
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = var.budget_alert_emails
  }
  notification {
    enabled        = true
    threshold      = 90
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = var.budget_alert_emails
  }
}

resource "databricks_cluster_policy" "dev_poc" {
  name = "${local.name_prefix}-poc-cost-control"
  definition = jsonencode({
    cluster_type            = { type = "allowlist", values = ["job", "all-purpose"] }
    node_type_id            = { type = "allowlist", values = ["Standard_DS3_v2"] }
    driver_node_type_id     = { type = "allowlist", values = ["Standard_DS3_v2"] }
    num_workers             = { type = "range", maxValue = 1, defaultValue = 1 }
    autotermination_minutes = { type = "range", minValue = 10, maxValue = 30, defaultValue = 15 }
    enable_elastic_disk     = { type = "fixed", value = true }
    custom_tags = {
      type = "fixed"
      value = {
        Project     = var.project_name
        Environment = "dev"
        CostCenter  = "dataplatform-dev"
        Workload    = "demo-poc"
      }
    }
  })
}
*/
