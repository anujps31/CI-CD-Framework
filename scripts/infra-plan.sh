#!/usr/bin/env bash
# Creates the reviewed Terraform/OpenTofu plan for the infrastructure pipeline.
# Runs inside AzureCLI@2 with addSpnToEnvironment: true, which provides $idToken,
# $servicePrincipalId and $tenantId for OIDC sign-in (no client secret).
set -euo pipefail

environment="${1:?environment is required}"
out_dir="${2:?output directory is required}"
allow_empty_state="${ALLOW_EMPTY_STATE:-False}"
infra_dir="infra"

export ARM_USE_OIDC=true
export ARM_OIDC_TOKEN="${idToken:?idToken is missing; enable addSpnToEnvironment on the AzureCLI task}"
export ARM_CLIENT_ID="${servicePrincipalId:?servicePrincipalId is missing}"
export ARM_TENANT_ID="${tenantId:?tenantId is missing}"
: "${ARM_SUBSCRIPTION_ID:?ARM_SUBSCRIPTION_ID is required}"

tf() { terraform -chdir="$infra_dir" "$@"; }

tf init -input=false -backend-config="environments/${environment}/backend.tfvars"

# Empty-state guard: an empty state against a live environment means the backend is
# pointing at the wrong key or container, and a plan would try to recreate everything.
# "state list" exits non-zero when no state exists at all, so treat that as zero.
resource_count="$({ tf state list 2>/dev/null || true; } | wc -l)"
echo "Resources tracked in state: ${resource_count}"
if [[ "$resource_count" -eq 0 && "$allow_empty_state" != "True" ]]; then
  echo "##vso[task.logissue type=error]State is empty. Check the backend key before planning; re-run with allowEmptyState only for a genuine first deployment."
  exit 1
fi

set +e
tf plan -input=false -var-file="environments/${environment}/${environment}.tfvars" -out=tfplan -detailed-exitcode
plan_rc=$?
set -e
case "$plan_rc" in
  0) has_changes=false ;;
  2) has_changes=true ;;
  *) echo "##vso[task.logissue type=error]Plan failed."; exit "$plan_rc" ;;
esac

# Delete gate: the pipeline never deletes or replaces resources. Intentional removals
# are reviewed and applied by a person from a workstation.
deletes="$(tf show -json tfplan | jq -r '[.resource_changes[]? | select(.change.actions | index("delete")) | .address] | .[]')"
if [[ -n "$deletes" ]]; then
  echo "##vso[task.logissue type=error]Plan would delete or replace these resources; apply blocked:"
  printf '  %s\n' $deletes
  exit 1
fi

# Readable plan for the approver, shown on the run's Summary tab.
mkdir -p "$out_dir"
plan_text="$(tf show -no-color tfplan)"
{
  echo "## Infrastructure plan: ${environment}"
  echo
  if [[ "$has_changes" == "true" ]]; then
    printf '%s\n' "$plan_text" | grep -E '^Plan:' || true
  else
    echo "No changes. Infrastructure matches the configuration; the Apply stage is skipped."
  fi
  echo
  echo '```text'
  printf '%s\n' "$plan_text" | head -n 3000
  echo '```'
} > "$out_dir/plan-summary.md"
echo "##vso[task.uploadsummary]$out_dir/plan-summary.md"

# Artifact for the Apply stage: configuration, lock file and saved plan, without the
# provider binaries (pipeline artifacts drop their execute permission).
cp -R "$infra_dir" "$out_dir/infra"
rm -rf "$out_dir/infra/.terraform"

echo "##vso[task.setvariable variable=hasChanges;isOutput=true]${has_changes}"