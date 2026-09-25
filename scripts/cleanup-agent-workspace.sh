#!/usr/bin/env bash
set -euo pipefail

# Keep the agent software and registration intact; remove only job data and caches.
agent_work_root="${AGENT_WORKFOLDER:-${AGENT_BUILDDIRECTORY:-/opt/azdo-agent/_work}}"
if [[ "$agent_work_root" != /* ]]; then
  agent_work_root="/opt/azdo-agent/$agent_work_root"
fi
if [[ -d "$agent_work_root" ]]; then
  find "$agent_work_root" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
fi

rm -rf "${HOME:-/home/azureagent}/.cache/pip" "${HOME:-/home/azureagent}/.npm/_cacache"
if command -v docker >/dev/null 2>&1; then
  # Labelled resources (SonarQube and its database) are long-lived and never pruned.
  docker system prune --all --force --volumes --filter "label!=com.dataplatform.keep=true" || true
fi
