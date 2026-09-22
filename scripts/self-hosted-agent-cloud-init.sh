#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl git jq unzip gnupg python3 python3-pip python3-venv nodejs npm docker.io
systemctl enable --now docker
usermod -aG docker azureagent

# Microsoft package repository for Azure CLI.
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
chmod a+r /etc/apt/keyrings/microsoft.gpg
printf '%s\n' "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ jammy main" >/etc/apt/sources.list.d/azure-cli.list
apt-get update
apt-get install -y azure-cli

# Terraform from the official HashiCorp release archive.
terraform_version="1.7.5"
curl -fsSLo /tmp/terraform.zip "https://releases.hashicorp.com/terraform/${terraform_version}/terraform_${terraform_version}_linux_amd64.zip"
unzip -o /tmp/terraform.zip -d /usr/local/bin
rm -f /tmp/terraform.zip

# kubectl from the stable Kubernetes release channel.
kubectl_version="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${kubectl_version}/bin/linux/amd64/kubectl"
chmod 0755 /usr/local/bin/kubectl

# Databricks unified CLI.
curl -fsSL https://raw.githubusercontent.com/databricks/setup-cli/main/install.sh | sh

# Keep all agent work and tool caches in a known location for cleanup jobs.
install -d -o azureagent -g azureagent /opt/azdo-agent /opt/azdo-agent/_work
cat >/etc/profile.d/azdo-agent-tools.sh <<'PROFILE'
export PATH="/usr/local/bin:$PATH"
PROFILE

printf '%s\n' 'Build-agent tools installed. Register the Azure DevOps agent separately with scripts/register-self-hosted-agent.sh.' >/var/log/build-agent-bootstrap.log
