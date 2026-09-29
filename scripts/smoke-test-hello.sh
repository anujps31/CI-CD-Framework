#!/usr/bin/env bash
# Hello-world smoke tests run by the workload pipeline after deployment. Each test proves a
# component actually works (not just that it exists). Runs inside AzureCLI@2, signed in as
# the service connection, on the self-hosted agent inside the VNet.
#   smoke-test-hello.sh adls <storage-account>
#   smoke-test-hello.sh adf  <resource-group> <factory-name>
#   smoke-test-hello.sh databricks <job-name>     (needs DATABRICKS_HOST; run after the adls test)
#   smoke-test-hello.sh web <resource-group> <aks-name> <namespace> [service]
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

test_databricks() {
  local job_name="${1:?job name is required}"
  local job_id run task_run_id result message read_build rows
  : "${DATABRICKS_HOST:?DATABRICKS_HOST is required}"

  job_id="$(databricks jobs list --name "$job_name" -o json \
    | jq -r 'if type == "array" then . else (.jobs // []) end | .[0].job_id // empty')"
  [[ -n "$job_id" ]] || fail "Databricks job ${job_name} not found; did the deploy step create it?"

  echo "Running ${job_name} (${job_id}); starting a single-node cluster takes a few minutes..."
  # run-now waits for the run to finish and fails if the run fails.
  run="$(databricks jobs run-now "$job_id" --timeout 30m -o json)" \
    || fail "Databricks job ${job_name} run failed; open the run in the workspace (Workflows) for the notebook error"
  [[ "$(jq -r .state.result_state <<<"$run")" == "SUCCESS" ]] \
    || fail "Databricks job ${job_name} ended as $(jq -r .state.result_state <<<"$run")"

  task_run_id="$(jq -r '.tasks[0].run_id' <<<"$run")"
  result="$(databricks jobs get-run-output "$task_run_id" -o json | jq -r .notebook_output.result)"
  message="$(jq -r .message <<<"$result")"
  read_build="$(jq -r .build_id <<<"$result")"
  rows="$(jq -r .rows <<<"$result")"

  [[ "$message" == "Hello World" ]] || fail "notebook returned message '${message}', expected 'Hello World'"
  # The notebook must have read the file written by this run's ADLS test, not an old copy.
  [[ "$read_build" == "$build_id" ]] || fail "notebook read build '${read_build}', expected this run's build '${build_id}'"
  pass "Databricks ${job_name} read '${message}' from build ${read_build} into $(jq -r .table <<<"$result") (${rows} row)"
}

test_web() {
  local rg="${1:?resource group is required}" aks="${2:?AKS name is required}"
  local namespace="${3:?namespace is required}" service="${4:-hello-web}"
  local work page ip
  work="$(mktemp -d)"
  export KUBECONFIG="${work}/kubeconfig"
  az aks get-credentials --resource-group "$rg" --name "$aks" --file "$KUBECONFIG" --overwrite-existing -o none \
    || fail "could not get credentials for AKS ${aks}"

  # Call the Service from inside the cluster: the public IP only admits the allowed client
  # ranges, and this agent is not one of them.
  # page="$(kubectl exec -n "$namespace" "deploy/${service}" -- wget -qO- "http://${service}.${namespace}.svc.cluster.local/")" \
  page="$(kubectl exec -n "$namespace" "deploy/${service}" -- wget -qO- "http://${service}-internal.${namespace}.svc.cluster.local/")" \
    || fail "could not reach service ${service} in namespace ${namespace}"
  grep -q "<h1>Hello World</h1>" <<<"$page" || fail "${service} did not return the Hello World page"
  grep -q ">${build_id}<" <<<"$page" || fail "${service} is not serving this build (${build_id}); an older version may still be running"
  pass "${service} answered inside the cluster with 'Hello World' for build ${build_id}"

  # Private path: this agent is inside the VNet, so it can call the internal load balancer
  # directly, exactly as the runner VM does.
  local private_ip public_ip private_page
  private_ip="$(kubectl get service "${service}-internal" -n "$namespace" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
  [[ -n "$private_ip" ]] || fail "${service}-internal has no private IP; run: kubectl describe service ${service}-internal -n ${namespace}"
  private_page="$(curl -fsS --max-time 15 "http://${private_ip}/")" \
    || fail "could not reach the private load balancer http://${private_ip}/ from inside the VNet"
  grep -q ">${build_id}<" <<<"$private_page" || fail "private load balancer is not serving build ${build_id}"
  pass "${service} answered over the VNet at http://${private_ip}/ (private) for build ${build_id}"

  public_ip="$(kubectl get service "$service" -n "$namespace" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
  echo "Browser (allowed IPs only): http://${public_ip:-<pending>}/"
  echo "Runner VM (curl):           http://${private_ip}/"
  rm -rf "$work"
}

case "${1:-}" in
  adls) shift; test_adls "$@" ;;
  adf)  shift; test_adf "$@" ;;
  databricks) shift; test_databricks "$@" ;;
  web) shift; test_web "$@" ;;
  *) echo "usage: $0 {adls <account> | adf <resource-group> <factory> | databricks <job-name> | web <resource-group> <aks> <namespace> [service]}" >&2; exit 2 ;;
esac