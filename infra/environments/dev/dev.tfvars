project_name             = "dataplatform"                           # Change for a different project naming prefix.
environment              = "dev"                                    # Must match the dev branch deployment target.
location                 = "eastus"                                 # Azure region for Development resources.
resource_group_name      = "NA_ResourceRG"                          # Existing target resource group.
subscription_id          = "d5691146-731e-4c08-92d4-b0b2703db592"   # Target Azure subscription.
tenant_id                = "c7ac8f34-d29e-4f96-b9c9-c50d7c861f3b"   # Azure AD tenant for this subscription.
dev_admin_object_ids     = ["fa6eca8d-3824-4f3d-9ef3-dfb98d42af17"] # Signed-in admin's object ID; owns the platform-admins group.
manage_access_control    = false                                    # Deploying identity has Contributor only on NA_ResourceRG, no RBAC or Entra admin rights.
enable_databricks        = true
# Enable only during the separate self-hosted-agent bootstrap apply.
databricks_host          = null
databricks_account_id    = null
databricks_client_id     = null
databricks_client_secret = null
# DEFERRED: configure budget alert recipients after Dev functional testing.
# budget_alert_emails      = []
