#!/usr/bin/env bash
set -euo pipefail
# Convert the selected profile into the Terraform and workload deployment actions.

environment="${1:?environment is required}" # This framework is Dev-only: always dev.
profile="${2:?deployment profile is required}" # FULL_PLATFORM, ADF_DATABRICKS, DATABRICKS_DABS, ADF_ONLY, or MICROSERVICES_ONLY.
artifact_dir="${3:?artifact directory is required}" # Published build artifact root.
resource_group="${RESOURCE_GROUP_NAME:?RESOURCE_GROUP_NAME is required}" # Target Azure resource group.
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

deploy_adf=false
deploy_databricks=false
deploy_microservices=false
use_dabs=false
enable_databricks=false
enable_microservices=false

case "$profile" in
  # Keep these flags aligned with the deployment profiles documented in README2.md.
  FULL_PLATFORM)
    deploy_adf=true; deploy_databricks=true; deploy_microservices=true
    enable_databricks=true; enable_microservices=true
    ;;
  ADF_DATABRICKS)
    deploy_adf=true; deploy_databricks=true; enable_databricks=true
    ;;
  DATABRICKS_DABS)
    deploy_databricks=true; use_dabs=true; enable_databricks=true
    ;;
  ADF_ONLY)
    deploy_adf=true
    ;;
  MICROSERVICES_ONLY)
    deploy_microservices=true; enable_microservices=true
    ;;
  *)
    echo "Unsupported deployment profile: $profile" >&2
    exit 1
    ;;
esac

# Each environment uses a separate Terraform backend state key.
terraform -chdir="${artifact_dir}/infra" init -backend-config="environments/${environment}/backend.tfvars" -input=false
terraform -chdir="${artifact_dir}/infra" apply -auto-approve -input=false \
  -var-file="environments/${environment}/${environment}.tfvars" \
  -var="enable_databricks=${enable_databricks}" \
  -var="enable_microservices=${enable_microservices}"

if [[ "$deploy_adf" == true ]]; then
  "${script_dir}/deploy-adf.sh" "$environment" "$resource_group" "${artifact_dir}/adf"
fi

if [[ "$deploy_databricks" == true ]]; then
  export DATABRICKS_HOST="${DATABRICKS_HOST:?DATABRICKS_HOST is required for Databricks profiles}"
  if [[ "$use_dabs" == true ]]; then
    (cd "${artifact_dir}/dabs" && databricks bundle validate -t "$environment" && databricks bundle deploy -t "$environment")
  else
    "${script_dir}/deploy-databricks.sh" "$environment" "$artifact_dir"
  fi
fi

if [[ "$deploy_microservices" == true ]]; then
  "${script_dir}/deploy-microservice.sh" "$environment" "$resource_group" "${ACR_NAME:?ACR_NAME is required}" "${AKS_NAME:?AKS_NAME is required}" "$artifact_dir"
fi