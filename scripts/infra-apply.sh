#!/usr/bin/env bash
# Applies exactly the saved plan produced by infra-plan.sh, after approval.
# If state changed since the plan was made, the apply refuses as a stale plan.
set -euo pipefail

environment="${1:?environment is required}"
plan_dir="${2:?directory containing the infra-plan artifact is required}"

export ARM_USE_OIDC=true
export ARM_OIDC_TOKEN="${idToken:?idToken is missing; enable addSpnToEnvironment on the AzureCLI task}"
export ARM_CLIENT_ID="${servicePrincipalId:?servicePrincipalId is missing}"
export ARM_TENANT_ID="${tenantId:?tenantId is missing}"
: "${ARM_SUBSCRIPTION_ID:?ARM_SUBSCRIPTION_ID is required}"

tf() { terraform -chdir="${plan_dir}/infra" "$@"; }

tf init -input=false -backend-config="environments/${environment}/backend.tfvars"
tf apply -input=false tfplan