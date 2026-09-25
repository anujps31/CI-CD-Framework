#!/usr/bin/env bash
set -euo pipefail

environment="${1:?environment is required}"
profile="${2:?deployment profile is required}"

case "$environment" in
  dev) ;;
  *) echo "Unsupported environment: $environment; this Terraform implementation supports dev only" >&2; exit 1 ;;
esac

case "$profile" in
  FULL_PLATFORM|ADF_DATABRICKS|DATABRICKS_DABS|ADF_ONLY|MICROSERVICES_ONLY) ;;
  *) echo "Unsupported deployment profile: $profile" >&2; exit 1 ;;
esac

require_value() {
  local variable_name="$1"
  [[ -n "${!variable_name:-}" ]] || {
    echo "$variable_name is required for $profile in $environment" >&2
    exit 1
  }
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "$1 is required on the deployment agent" >&2
    exit 1
  }
}

# These values are supplied by the Azure DevOps service connection or variable group.
for required in ARM_SUBSCRIPTION_ID ARM_TENANT_ID ARM_CLIENT_ID RESOURCE_GROUP_NAME; do
  require_value "$required"
done

for required_command in az terraform; do
  require_command "$required_command"
done

case "$profile" in
  FULL_PLATFORM|ADF_DATABRICKS|ADF_ONLY)
    require_command python3
    ;;
esac

case "$profile" in
  FULL_PLATFORM|ADF_DATABRICKS|DATABRICKS_DABS)
    # The first Terraform apply can discover the workspace URL from Azure. The CLI
    # deployment below still requires the URL after Terraform has completed.
    for required in DATABRICKS_CLIENT_ID DATABRICKS_CLIENT_SECRET DATABRICKS_ACCOUNT_ID; do
      require_value "$required"
    done
    require_command databricks
    ;;
esac

case "$profile" in
  FULL_PLATFORM|MICROSERVICES_ONLY)
    for required in ACR_NAME AKS_NAME; do
      require_value "$required"
    done
    require_command docker
    require_command kubectl
    ;;
esac

printf 'Pre-deployment configuration is present for %s (%s).\n' "$environment" "$profile"
