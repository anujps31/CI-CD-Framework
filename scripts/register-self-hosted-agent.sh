#!/usr/bin/env bash
set -euo pipefail

agent_root="${AGENT_ROOT:-/opt/azdo-agent}"
agent_user="${AGENT_USER:-azureagent}"
azp_url="${AZP_URL:?AZP_URL is required, for example https://dev.azure.com/your-org}"
azp_pool="${AZP_POOL:-azure-data-platform}"
azp_agent="${AZP_AGENT_NAME:-$(hostname)}"
azp_token="${AZP_TOKEN:?AZP_TOKEN is required and must be supplied as a secret environment variable}"
agent_version="${AZP_AGENT_VERSION:-4.260.0}"

id "$agent_user" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$agent_user"
install -d -o "$agent_user" -g "$agent_user" "$agent_root"
cd "$agent_root"

if [[ ! -f .agent ]]; then
  curl -fsSLo agent.tar.gz "https://vstsagentpackage.azureedge.net/agent/${agent_version}/vsts-agent-linux-x64-${agent_version}.tar.gz"
  tar -xzf agent.tar.gz
  rm -f agent.tar.gz
  chown -R "$agent_user":"$agent_user" "$agent_root"
fi

# The token is supplied only at registration time and is not written into this script.
sudo -u "$agent_user" env AZP_TOKEN="$azp_token" ./config.sh \
  --unattended \
  --url "$azp_url" \
  --auth pat \
  --token "$azp_token" \
  --pool "$azp_pool" \
  --agent "$azp_agent" \
  --work _work \
  --replace \
  --acceptTeeEula

unset azp_token AZP_TOKEN
chown -R "$agent_user":"$agent_user" "$agent_root"
./svc.sh install "$agent_user"
./svc.sh start
printf '%s\n' "Agent ${azp_agent} registered in pool ${azp_pool}."