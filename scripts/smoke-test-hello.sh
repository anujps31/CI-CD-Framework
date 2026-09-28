#!/usr/bin/env bash
# Hello-world smoke tests run by the workload pipeline after deployment. Each test proves a
# component actually works (not just that it exists). Runs inside AzureCLI@2, signed in as
# the service connection, on the self-hosted agent inside the VNet.
#   smoke-test-hello.sh adls <storage-account>
#   smoke-test-hello.sh adf  <resource-group> <factory-name>
set -euo pipefail

build_id="${BUILD_BUILDID:-local}"

pass() { echo "PASS: $*"; }
fail() { echo "##vso[task.logissue type=error]FAIL: $*"; exit 1; }

test_adls() {
  local account="${1:?storage account is required}"
  local container="raw" path="landing/hello/hello.csv"
  local work; work="$(mktemp -d)"
  printf 'message,build_id\nHello World,%s\n' "$build_id" > "$work/hello.csv"

  # Private endpoint + Entra ID data-plane access (shared keys are disabled on this account).
  az storage blob upload --auth-mode login --only-show-errors --overwrite \
    --account-name "$account" --container-name "$container" --name "$path" --file "$work/hello.csv" -o none \
    || fail "could not write ${container}/${path} to ${account}"
  az storage blob download --auth-mode login --only-show-errors \
    --account-name "$account" --container-name "$container" --name "$path" --file "$work/readback.csv" -o none \
    || fail "could not read ${container}/${path} back from ${account}"

  cmp -s "$work/hello.csv" "$work/readback.csv" || fail "ADLS read-back did not match what was written"
  pass "ADLS wrote and read ${container}/${path} (build ${build_id})"
  rm -rf "$work"
}

test_adf() {
  local rg="${1:?resource group is required}" factory="${2:?factory name is required}"
  local sub api="api-version=2018-06-01" base run_id status value
  sub="$(az account show --query id -o tsv)"
  base="https://management.azure.com/subscriptions/${sub}/resourceGroups/${rg}/providers/Microsoft.DataFactory/factories/${factory}"

  run_id="$(az rest --method post --url "${base}/pipelines/pl_hello_world/createRun?${api}" --query runId -o tsv)" \
    || fail "could not start pl_hello_world in ${factory}"
  echo "Started pl_hello_world run ${run_id}"

  for _ in $(seq 1 30); do
    status="$(az rest --method get --url "${base}/pipelineruns/${run_id}?${api}" --query status -o tsv)"
    case "$status" in
      Succeeded) break ;;
      Failed|Cancelled) fail "pl_hello_world run ${run_id} ended as ${status}" ;;
    esac
    sleep 10
  done
  [[ "$status" == "Succeeded" ]] || fail "pl_hello_world run ${run_id} still ${status} after 5 minutes"

  # Check the activity really produced the value, not just that the run finished.
  value="$(az rest --method post --url "${base}/pipelineruns/${run_id}/queryActivityruns?${api}" \
    --body "{\"lastUpdatedAfter\":\"$(date -u -d '-1 hour' +%FT%TZ)\",\"lastUpdatedBefore\":\"$(date -u -d '+1 hour' +%FT%TZ)\"}" \
    --query "value[?activityName=='SetGreeting'].output.value | [0]" -o tsv)"
  [[ "$value" == "Hello World" ]] || fail "SetGreeting output was '${value}', expected 'Hello World'"
  pass "ADF pl_hello_world run ${run_id} Succeeded with output '${value}'"
}

case "${1:-}" in
  adls) shift; test_adls "$@" ;;
  adf)  shift; test_adf "$@" ;;
  *) echo "usage: $0 {adls <account> | adf <resource-group> <factory>}" >&2; exit 2 ;;
esac