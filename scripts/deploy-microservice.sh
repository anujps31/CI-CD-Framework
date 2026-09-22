#!/usr/bin/env bash
set -euo pipefail
# Build the image in ACR and apply the environment-substituted Kubernetes manifest.
environment="${1:?environment is required}" # This framework is Dev-only: always dev.
resource_group="${2:?resource group is required}" # Target AKS resource group.
acr_name="${3:?ACR name is required}" # ACR-NAME variable group value.
aks_name="${4:?AKS name is required}" # AKS-NAME variable group value.
artifact_dir="${5:?artifact directory is required}" # Build artifact root.
service_name="${6:-orders-api}" # Kubernetes Deployment and image name.
image_tag="${BUILD_BUILDID:-${BUILD_NUMBER:-local}}"
image="${acr_name}.azurecr.io/${service_name}:${image_tag}"
service_dir="${artifact_dir}/microservices/${service_name}"
manifest="${service_dir}/k8s/deployment.yml"

az acr build --registry "$acr_name" --image "$image" "$service_dir"
az aks get-credentials --resource-group "$resource_group" --name "$aks_name" --overwrite-existing
sed -e "s|__IMAGE__|${image}|g" -e "s|__ENVIRONMENT__|${environment}|g" "$manifest" | kubectl apply -f -
kubectl rollout status deployment/"$service_name" --timeout=180s
