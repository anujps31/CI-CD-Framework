#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update

apt-get install -y ca-certificates curl git jq unzip gnupg python3 python3-pip python3-venv docker.io shellcheck libicu70 liblttng-ust1
systemctl enable --now docker
id azureagent >/dev/null 2>&1 || useradd --create-home --shell /bin/bash azureagent
usermod -aG docker azureagent

# Node.js 20 LTS from NodeSource. The distro's own nodejs/npm package is intentionally
# left out of the apt-get install above: Ubuntu jammy ships Node 12 (long past EOL), and
# libnode-dev from that package conflicts with NodeSource's file layout on upgrade
# (dpkg refuses to overwrite /usr/include/node/common.gypi). Removing it first avoids
# that conflict on both fresh installs and any future re-provisioning of this script.
apt-get remove -y libnode-dev || true
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

# Microsoft package repository for Azure CLI.
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
chmod a+r /etc/apt/keyrings/microsoft.gpg
printf '%s\n' "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ jammy main" >/etc/apt/sources.list.d/azure-cli.list
apt-get update
apt-get install -y azure-cli

# OpenTofu is the open-source Terraform-compatible CLI used by the existing pipeline commands.
opentofu_version="1.7.3"
curl -fsSLo /tmp/tofu.zip "https://github.com/opentofu/opentofu/releases/download/v${opentofu_version}/tofu_${opentofu_version}_linux_amd64.zip"
unzip -o /tmp/tofu.zip -d /usr/local/bin
ln -sf /usr/local/bin/tofu /usr/local/bin/terraform
rm -f /tmp/tofu.zip

# kubectl from the stable Kubernetes release channel.
kubectl_version="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${kubectl_version}/bin/linux/amd64/kubectl"
chmod 0755 /usr/local/bin/kubectl

# Databricks unified CLI (open source).
curl -fsSL https://raw.githubusercontent.com/databricks/setup-cli/main/install.sh | sh

# Open-source Terraform and secret/vulnerability scanners used by Azure DevOps.
tflint_version="0.53.0"
curl -fsSLo /tmp/tflint.zip "https://github.com/terraform-linters/tflint/releases/download/v${tflint_version}/tflint_linux_amd64.zip"
unzip -o /tmp/tflint.zip -d /usr/local/bin
rm -f /tmp/tflint.zip

install -d /opt/ci-tools
python3 -m venv /opt/ci-tools/venv
/opt/ci-tools/venv/bin/pip install --upgrade pip checkov coverage
ln -sf /opt/ci-tools/venv/bin/checkov /usr/local/bin/checkov
ln -sf /opt/ci-tools/venv/bin/coverage /usr/local/bin/coverage

gitleaks_version="8.18.4"
curl -fsSLo /tmp/gitleaks.tar.gz "https://github.com/gitleaks/gitleaks/releases/download/v${gitleaks_version}/gitleaks_${gitleaks_version}_linux_x64.tar.gz"
tar -xzf /tmp/gitleaks.tar.gz -C /usr/local/bin gitleaks
rm -f /tmp/gitleaks.tar.gz

# NOTE: pin bumped from 0.50.4 -> 0.74.0. The 0.50.4 release was removed from GitHub's
# release list, which made this download 404 silently during boot (curl -f swallowed the
# error and the script kept going, so trivy just never appeared, no error surfaced during
# apply). Re-check https://github.com/aquasecurity/trivy/releases periodically since this
# pin will go stale again the same way.
trivy_version="0.74.0"
curl -fsSLo /tmp/trivy.tar.gz "https://github.com/aquasecurity/trivy/releases/download/v${trivy_version}/trivy_${trivy_version}_Linux-64bit.tar.gz"
tar -xzf /tmp/trivy.tar.gz -C /usr/local/bin trivy
rm -f /tmp/trivy.tar.gz

# SonarSource scanner CLI is used by the Azure DevOps SonarQube tasks.
# -o forces overwrite on unzip: without it, a re-run of this script (or any prior partial
# extraction) drops unzip into an interactive "replace file?" prompt with no TTY to answer
# it, which hangs the script indefinitely on first boot.
sonar_scanner_version="5.0.1.3006"
curl -fsSLo /tmp/sonar-scanner.zip "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${sonar_scanner_version}-linux.zip"
unzip -o -q /tmp/sonar-scanner.zip -d /opt/ci-tools
ln -sfn "/opt/ci-tools/sonar-scanner-${sonar_scanner_version}-linux" /opt/ci-tools/sonar-scanner
ln -sf /opt/ci-tools/sonar-scanner/bin/sonar-scanner /usr/local/bin/sonar-scanner
rm -f /tmp/sonar-scanner.zip

# Keep all agent work and tool caches in a known location for cleanup jobs.
install -d -o azureagent -g azureagent /opt/azdo-agent /opt/azdo-agent/_work
cat >/etc/profile.d/azdo-agent-tools.sh <<'PROFILE'
export PATH="/usr/local/bin:$PATH"
PROFILE

printf '%s\n' 'Azure DevOps runner tools installed. Register the agent separately with scripts/register-self-hosted-agent.sh.' >/var/log/azdo-runner-bootstrap.log