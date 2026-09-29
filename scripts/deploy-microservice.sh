#!/usr/bin/env bash
set -euo pipefail
# Build the image on this agent, push it to the private ACR, and roll it out to AKS.
# The build runs here (not "az acr build") because ACR public access is disabled and only
# this agent, inside the VNet, can reach the registry over its private endpoint.
environment="${1:?environment is required}"   # This framework is Dev-only: always dev.
resource_group="${2:?resource group is required}"
acr_name="${3:?ACR name is required}"          # ACR-NAME variable group value.
aks_name="${4:?AKS name is required}"          # AKS-NAME variable group value.
artifact_dir="${5:?artifact directory is required}"
service_name="${6:-hello-web}"
# allowed_cidrs="${ALLOWED_CIDRS:?ALLOWED_CIDRS is required, for example 1.2.3.4/32,5.6.7.8/32}"
allowed_cidrs="${ALLOWED_CIDRS:-}"   # Only needed while the manifest has a public Service.

image_tag="${BUILD_BUILDID:-local}"
image="${acr_name}.azurecr.io/${service_name}:${image_tag}"
namespace="$environment"
work="$(mktemp -d)"
export KUBECONFIG="${work}/kubeconfig"
trap 'rm -rf "$work"' EXIT

# Stamp the page with the environment and build, so the smoke test can prove this build is live.
cp -R "${artifact_dir}/microservices/${service_name}" "${work}/src"
sed -i -e "s|__BUILD_ID__|${image_tag}|g" -e "s|__ENVIRONMENT__|${environment}|g" "${work}/src/index.html"

az acr login --name "$acr_name"
docker build --pull --tag "$image" "${work}/src"
docker push "$image"
docker image rm "$image" >/dev/null 2>&1 || true

az aks get-credentials --resource-group "$resource_group" --name "$aks_name" --file "$KUBECONFIG" --overwrite-existing
kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -

# "1.2.3.4/32,5.6.7.8/32" -> ["1.2.3.4/32","5.6.7.8/32"] for loadBalancerSourceRanges.
cidr_list="[\"${allowed_cidrs//,/\",\"}\"]"
sed -e "s|__IMAGE__|${image}|g" -e "s|__ENVIRONMENT__|${environment}|g" -e "s|__ALLOWED_CIDRS__|${cidr_list}|g" \
  "${work}/src/k8s/deployment.yml" | kubectl apply -n "$namespace" -f -
kubectl rollout status "deployment/${service_name}" -n "$namespace" --timeout=300s

# New load balancer IPs can take a couple of minutes to be assigned.
wait_for_ip() {
  local svc="$1" ip=""
  for _ in $(seq 1 30); do
    ip="$(kubectl get service "$svc" -n "$namespace" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
    [[ -n "$ip" ]] && break
    sleep 10
  done
  printf '%s' "$ip"
}
# public_ip="$(wait_for_ip "$service_name")"
public_ip=""
if kubectl get service "$service_name" -n "$namespace" >/dev/null 2>&1; then
  public_ip="$(wait_for_ip "$service_name")"
fi
private_ip="$(wait_for_ip "${service_name}-internal")"

if [[ -n "$public_ip" ]]; then
  echo "Public:  http://${public_ip}/  (only from: ${allowed_cidrs})"
else
  # echo "##vso[task.logissue type=warning]${service_name} has no public IP yet; check: kubectl get service ${service_name} -n ${namespace}"
  echo "No public Service (private only)."
fi
if [[ -n "$private_ip" ]]; then
  echo "Private: http://${private_ip}/  (only from inside the VNet, e.g. the runner VM)"
else
  echo "##vso[task.logissue type=warning]${service_name}-internal has no private IP yet; check: kubectl describe service ${service_name}-internal -n ${namespace}"
fi