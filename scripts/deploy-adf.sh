#!/usr/bin/env bash
set -euo pipefail
# Deploy the selected environment's published ADF ARM artifact.
environment="${1:?environment is required}" # This framework is Dev-only: always dev.
resource_group="${2:?resource group is required}" # Resource group from the environment variable group.
artifact_dir="${3:?artifact directory is required}" # Build artifact containing the ADF export.
# These filenames must match the ADF publish export stored in the repository.
template="${artifact_dir}/exportedArmTemplate/ARMTemplateForFactory.json"
parameters="${artifact_dir}/exportedArmTemplate/ARMTemplateParametersFor-${environment}.json"
if [[ ! -f "$template" ]]; then
  echo "ADF ARM template not found at $template" >&2
  exit 1
fi
if [[ ! -f "$parameters" ]]; then
  echo "ADF ARM parameters not found at $parameters" >&2
  exit 1
fi
az deployment group validate --resource-group "$resource_group" --template-file "$template" --parameters "@$parameters"
az deployment group create --resource-group "$resource_group" --template-file "$template" --parameters "@$parameters" --mode Incremental
