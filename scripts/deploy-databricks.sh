#!/usr/bin/env bash
set -euo pipefail
# Import notebooks, then create or update every job defined under databricks/jobs/.
# Jobs are matched by name, so no job IDs need to be stored in the repository.
environment="${1:?environment is required}" # This framework is Dev-only: always dev.
artifact_dir="${2:?artifact directory is required}" # Build artifact root.
export DATABRICKS_HOST="${DATABRICKS_HOST:?DATABRICKS_HOST is required}"

# Notebooks are isolated under a workspace folder named for the target environment.
# Files starting with "# Databricks notebook source" become runnable notebooks.
notebooks="${artifact_dir}/notebooks"
if [[ -d "$notebooks" ]]; then
  databricks workspace import-dir "$notebooks" "/Shared/${environment}" --overwrite
fi

jobs_dir="${artifact_dir}/databricks/jobs"
[[ -d "$jobs_dir" ]] || { echo "No job definitions found under databricks/jobs; skipping jobs."; exit 0; }
for spec in "$jobs_dir"/*.json; do
  [[ -e "$spec" ]] || continue
  rendered="$(mktemp)"
  sed "s/__ENVIRONMENT__/${environment}/g" "$spec" > "$rendered"
  # Optional "access_control_list" in a job file is applied separately: the Jobs create/reset
  # settings don't carry permissions, and update-permissions only adds, never removes.
  acl="$(jq -c '.access_control_list // empty' "$rendered")"
  jq 'del(.access_control_list)' "$rendered" > "${rendered}.settings" && mv "${rendered}.settings" "$rendered"
  name="$(jq -r .name "$rendered")"
  job_id="$(databricks jobs list --name "$name" -o json \
    | jq -r 'if type == "array" then . else (.jobs // []) end | .[0].job_id // empty')"
  if [[ -z "$job_id" ]]; then
    job_id="$(databricks jobs create --json "@${rendered}" -o json | jq -r .job_id)"
    echo "Created job ${name} (${job_id})"
  else
    jq -n --argjson id "$job_id" --slurpfile s "$rendered" '{job_id: $id, new_settings: $s[0]}' > "${rendered}.reset"
    databricks jobs reset --json "@${rendered}.reset"
    echo "Updated job ${name} (${job_id})"
  fi
  if [[ -n "$acl" ]]; then
    databricks jobs update-permissions "$job_id" --json "{\"access_control_list\": ${acl}}" > /dev/null
    echo "Applied permissions to job ${name}"
  fi
  rm -f "$rendered" "${rendered}.reset"
done