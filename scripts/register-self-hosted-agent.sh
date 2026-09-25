#!/usr/bin/env bash
# Registers this VM as an Azure DevOps agent and installs it as a systemd service, so it
# reconnects automatically after every reboot. Safe to re-run: an agent that is already
# registered is only (re)started, never re-registered.
#
# Settings come from environment variables, or from the VM's Azure tags (set by Terraform):
#   AZP_URL          tag azdo-org-url     e.g. https://dev.azure.com/syrentechnologies
#   AZP_POOL         tag azdo-pool        default azure-data-platform
#   KEY_VAULT_NAME   tag azdo-key-vault   Key Vault holding the registration PAT
#   AZP_PAT_SECRET   tag azdo-pat-secret  default azdo-agent-pat
#   AZP_TOKEN        the PAT itself; when unset it is read from Key Vault with the VM's
#                    managed identity, so no secret ever lives in Terraform or cloud-init.
set -euo pipefail

agent_root="${AGENT_ROOT:-/opt/azdo-agent}"
agent_user="${AGENT_USER:-azureagent}"
agent_version="${AZP_AGENT_VERSION:-5.279.0}"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

# Reads one tag from the Azure Instance Metadata Service; prints nothing if absent.
vm_tag() {
  curl -fsS -H Metadata:true --noproxy '*' \
    "http://169.254.169.254/metadata/instance/compute/tagsList?api-version=2021-02-01" 2>/dev/null \
    | jq -r --arg n "$1" '.[] | select(.name == $n) | .value' 2>/dev/null || true
}

start_agent_service() {
  cd "$agent_root"
  # UsePythonVersion/UseNode download builds that are compiled for /opt/hostedtoolcache.
  install -d -o "$agent_user" -g "$agent_user" /opt/hostedtoolcache
  grep -q '^AGENT_TOOLSDIRECTORY=' .env 2>/dev/null || echo 'AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache' >>.env
  # svc.sh writes .service after installing the systemd unit; install only once.
  [[ -f .service ]] || ./svc.sh install "$agent_user"
  ./svc.sh start
}

id "$agent_user" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$agent_user"
install -d -o "$agent_user" -g "$agent_user" "$agent_root"

# Already registered: make sure the service is installed and running, then stop here.
if [[ -f "$agent_root/.credentials" ]]; then
  start_agent_service
  echo "Agent already registered; service started."
  exit 0
fi

azp_url="${AZP_URL:-$(vm_tag azdo-org-url)}"
azp_pool="${AZP_POOL:-$(vm_tag azdo-pool)}"
azp_pool="${azp_pool:-azure-data-platform}"
azp_agent="${AZP_AGENT_NAME:-$(hostname)}"
kv_name="${KEY_VAULT_NAME:-$(vm_tag azdo-key-vault)}"
pat_secret="${AZP_PAT_SECRET:-$(vm_tag azdo-pat-secret)}"
pat_secret="${pat_secret:-azdo-agent-pat}"

if [[ -z "$azp_url" ]]; then
  echo "AZP_URL is not set and the VM has no azdo-org-url tag." >&2
  exit 1
fi

token="${AZP_TOKEN:-}"
if [[ -z "$token" ]]; then
  if [[ -z "$kv_name" ]]; then
    echo "AZP_TOKEN is not set and the VM has no azdo-key-vault tag to read it from." >&2
    exit 1
  fi
  az login --identity --allow-no-subscriptions --output none
  token="$(az keyvault secret show --vault-name "$kv_name" --name "$pat_secret" --query value -o tsv)"
  az account clear
fi

# Download the agent once. Microsoft retired the old vstsagentpackage.azureedge.net CDN.
if [[ ! -x "$agent_root/config.sh" ]]; then
  curl -fsSLo /tmp/azdo-agent.tar.gz \
    "https://download.agent.dev.azure.com/agent/${agent_version}/vsts-agent-linux-x64-${agent_version}.tar.gz"
  tar -xzf /tmp/azdo-agent.tar.gz -C "$agent_root"
  rm -f /tmp/azdo-agent.tar.gz
  chown -R "$agent_user":"$agent_user" "$agent_root"
fi

# The agent reads VSTS_AGENT_INPUT_TOKEN, which keeps the PAT off the process command line.
cd "$agent_root"
export VSTS_AGENT_INPUT_TOKEN="$token"
sudo --preserve-env=VSTS_AGENT_INPUT_TOKEN -u "$agent_user" ./config.sh \
  --unattended \
  --url "$azp_url" \
  --auth pat \
  --pool "$azp_pool" \
  --agent "$azp_agent" \
  --work _work \
  --replace \
  --acceptTeeEula
unset VSTS_AGENT_INPUT_TOKEN token

start_agent_service
echo "Agent ${azp_agent} registered in pool ${azp_pool}."