#!/usr/bin/env bash
set -euo pipefail
# Import notebooks and update an existing Databricks job when its specification is present.
environment="${1:?environment is required}" # This framework is Dev-only: always dev.
artifact_dir="${2:?artifact directory is required}" # Build artifact root.
export DATABRICKS_HOST="${DATABRICKS_HOST:?DATABRICKS_HOST is required after Terraform creates the workspace}"
# Notebooks are isolated under a workspace folder named for the target environment.
notebooks="${artifact_dir}/notebooks"
if [[ -d "$notebooks" ]]; then
  databricks workspace import-dir "$notebooks" "/Shared/${environment}" --overwrite
fi
job_id_file="${artifact_dir}/databricks/job_id_${environment}.txt"
job_spec_file="${artifact_dir}/databricks/job_spec_${environment}.json"
if [[ -f "$job_id_file" && -f "$job_spec_file" ]]; then
  databricks jobs reset --job-id "$(<"$job_id_file")" --json "@$job_spec_file"
fi
