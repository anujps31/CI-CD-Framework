# Development Deployment Runbook

This runbook deploys the repository to the single supported environment:

- Azure subscription: `d5691146-731e-4c08-92d4-b0b2703db592`
- Tenant: `c7ac8f34-d29e-4f96-b9c9-c50d7c861f3b`
- Resource group: `NA_ResourceRG`
- Environment: `dev`
- Deployment branch: `dev`

The repository is not multi-environment ready. Do not change the environment name,
resource group, backend key, or branch without adding a separate Terraform environment,
state key, pipeline stage, and variable group.

## 1. Deployment Order

The dependency order is intentional:

1. Confirm Azure, Databricks, network, quota, and agent prerequisites.
2. Create the Terraform remote state storage account and container once.
3. Create the Azure DevOps service connection, variable groups, agent pool, and `dev`
   environment.
4. Run CI: unit tests, Terraform validation, code quality, and vulnerability scans.
5. Publish one immutable artifact containing `infra`, `adf`, `notebooks`, `dabs`,
   `microservices`, `projects`, and `scripts`.
6. Initialize Terraform against the remote backend.
7. Apply the Azure foundation. Terraform creates the resource group data boundary,
   network, private DNS, Key Vault, ADLS, ADF, and optional Databricks or AKS resources.
8. Deploy the ADF ARM export after Terraform has created the ADF factory.
9. Deploy Databricks notebooks and jobs, or deploy the Databricks Asset Bundle.
10. Build the orders API in ACR and roll it out to AKS when the profile includes
    microservices.
11. Run the Azure resource smoke test and inspect workload-specific health.

Terraform must finish before ADF, Databricks, or AKS deployment. ADF must exist before
its ARM export is applied. AKS and ACR must exist before the container build and rollout.
The pipeline stage dependencies enforce this order.

## 2. Required Access and Quotas

The deployment identity needs all of the following before the first run:

- `Contributor` on `NA_ResourceRG`.
- `Storage Blob Data Contributor` on the Terraform state container.
- `User Access Administrator` or `Owner` if `manage_access_control = true` or if
  Terraform must create role assignments.
- Microsoft Graph/Entra permissions if Terraform must create groups, users, or memberships.
- Databricks account-level permission to create or manage the Unity Catalog metastore and
  assign the workspace when a Databricks profile is selected.
- `AcrPush` on ACR and AKS Cluster User access for the microservice deployment identity.
- Permission to read the private endpoints and private DNS zones created by Terraform.

The subscription must have capacity for private endpoints, VNet-injected Premium
Databricks, a private AKS cluster, public IP-free Databricks networking, and the selected
VM size. The deployment agent must be able to resolve and reach private DNS names. A
public hosted agent cannot deploy or test these private resources reliably.

## 3. Deployment Agent

Use an Azure DevOps self-hosted agent in pool `azure-data-platform`. Install and verify:

| Tool | Minimum | Used by |
|---|---:|---|
| Azure CLI | 2.60 | Azure login and deployment |
| OpenTofu | 1.7 | Infrastructure and state, Terraform-compatible CLI |
| Databricks unified CLI | 0.220 | Classic notebooks/jobs and DABS |
| Python | 3.12 | Tests and notebook compilation |
| Node.js | 18 LTS | CI compatibility |
| Docker | 24 | Image build and scanning |
| kubectl | Current | AKS rollout |
| Bash | Current | All repository shell scripts |
| SonarQube scanner | 5+ | Quality gate |
| Trivy | 0.50+ | Filesystem and image scans |
| Gitleaks | 8+ | Secret scan |
| tflint and Checkov | Current | Optional checks when installed |

On a Linux agent, check the shell scripts with `bash -n scripts/*.sh`. The Windows
workstation used to edit this repository does not provide Bash by default; install Git
Bash or WSL for local script testing. Azure DevOps still requires a Bash-capable agent.

### Optional Terraform-managed Azure DevOps runner VM

The repository includes an opt-in private Ubuntu VM named
`vm-dataplatform-dev-azdo-runner-01` for all Azure DevOps pipeline scenarios. It is
disabled by default because the first Terraform apply must run on an already-available
bootstrap agent. The VM is created only when these values are supplied:

```hcl
enable_azdo_runner_vm      = true
azdo_runner_vm_size        = "Standard_D4s_v5"
azdo_runner_ssh_public_key = "ssh-ed25519 AAAA..."
```

Run the first apply from an existing agent with the VM flag and SSH public key. After the
VM is reachable through the VNet, VPN, or a private jump host, register it without putting
the Azure DevOps PAT in Terraform:

```bash
export AZP_URL="https://dev.azure.com/<organization>"
export AZP_POOL="azure-data-platform"
export AZP_AGENT_NAME="dataplatform-dev-agent"
export AZP_TOKEN="<secret-PAT>"
sudo ./scripts/register-self-hosted-agent.sh
```

Run this command from a repository checkout on the VM, or copy
`scripts/register-self-hosted-agent.sh` to the VM before execution. Use a short-lived PAT with only Agent Pools
read/manage permission, keep it in a secret variable, and rotate it after registration.
The Azure DevOps agent necessarily retains an encrypted registration credential locally
while it is registered; it cannot function with literally zero local state.

The VM does not have a public IP. Its subnet must have private DNS resolution and outbound
HTTPS access to Azure DevOps, package repositories, Azure, Databricks, and security scan
endpoints. The current VM NSG permits SSH only from the VNet. Do not expose port 22 to the
Internet.

### Build storage and cleanup

The pipeline cleanup steps run after every CI, deployment, and smoke-test job. They remove
the Azure DevOps work directory, pip/npm caches, and unused Docker images, containers,
networks, and volumes. The installed tools, VM operating system, agent registration, and
Terraform state remain. This prevents build data from filling the disk, but it does not
make the VM cost-free: the VM is billed while running.

For maximum cost savings, stop or deallocate the VM outside deployment windows, or use a
separate VM Scale Set/ephemeral agent design. Do not delete the VM while an Azure DevOps
job is running. The optional VM can be removed later with `enable_azdo_runner_vm = false`
and a Terraform apply after the agent is removed from the Azure DevOps pool.

## 4. One-Time Terraform State Bootstrap

The backend is deliberately outside the Terraform state it stores. Run these commands
once with an identity that can create storage resources. They use Azure CLI login rather
than storage keys.

```bash
az login --tenant c7ac8f34-d29e-4f96-b9c9-c50d7c861f3b
az account set --subscription d5691146-731e-4c08-92d4-b0b2703db592
az group show --name NA_ResourceRG --output none

az storage account create \
  --name sttfstatedatadev1 \
  --resource-group NA_ResourceRG \
  --location eastus \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --https-only true \
  --allow-blob-public-access false \
  --enable-hierarchical-namespace false

az storage container create \
  --account-name sttfstatedatadev1 \
  --name tfstate \
  --auth-mode login

az storage account blob-service-properties update \
  --account-name sttfstatedatadev1 \
  --resource-group NA_ResourceRG \
  --enable-versioning true
```

The values must match [infra/environments/dev/backend.tfvars](infra/environments/dev/backend.tfvars).
Never put a storage account key in source control or a pipeline variable.

## 5. Azure DevOps Setup

Create these objects exactly:

- Service connection: `svc-dataplatform-dev`
- Variable group: `vg-dataplatform-shared`
- Variable group: `vg-dataplatform-dev`
- Agent pool: `azure-data-platform`
- Environment: `dev`

Authorize both variable groups for the pipeline. Authorize the service connection for the
pipeline and authorize the `dev` environment for the deployment stage.

### Shared or development variables

The active scope is limited to ADLS, ADF, Databricks, managed identities, and Key Vault.
Microservices, ACR, AKS, and the optional Azure DevOps runner VM are disabled for this phase.

Variable names in Azure DevOps use hyphens; Bash receives the corresponding underscore
form through the task environment.

| Variable | Secret | Required for |
|---|---:|---|
| `ARM-SUBSCRIPTION-ID` | No | All profiles |
| `ARM-TENANT-ID` | No | All profiles |
| `ARM-CLIENT-ID` | No | All profiles |
| `RESOURCE-GROUP-NAME` | No | All profiles; set to `NA_ResourceRG` |
| `DATABRICKS-HOST` | No | Databricks workload deployment after workspace creation |
| `DATABRICKS-ACCOUNT-ID` | No | Databricks Terraform/Unity Catalog |
| `DATABRICKS-CLIENT-ID` | Yes | Databricks Terraform and CLI |
| `DATABRICKS-CLIENT-SECRET` | Yes | Databricks Terraform and CLI |
| `ACR-NAME` | No | Not required for the active scope |
| `AKS-NAME` | No | Not required for the active scope |

Use the actual Terraform outputs for `DATABRICKS-HOST`, `ACR-NAME`, and `AKS-NAME`:

```bash
terraform -chdir=infra output -raw databricks_workspace_url
terraform -chdir=infra output -raw acr_name
terraform -chdir=infra output -raw aks_name
```

The first Databricks apply can derive the workspace resource from Azure, but the
subsequent CLI deployment requires the workspace URL. Save that URL in the variable group
before rerunning the workload deployment if it was initially blank.

## 6. Terraform Inputs

Review [infra/environments/dev/dev.tfvars](infra/environments/dev/dev.tfvars) before the
first apply:

- `resource_group_name` must remain `NA_ResourceRG`.
- `subscription_id` and `tenant_id` must match the target subscription.
- `location` must support all selected Azure services.
- `dev_admin_object_ids` must contain real Entra object IDs when access control is enabled.
- Keep `manage_access_control = false` when the deploying identity has only Contributor.
  An administrator must then create required RBAC, Entra, and Databricks grants separately.
- Keep `manage_access_control = true` only after confirming Graph and RBAC permissions.

The pipeline overrides `enable_databricks` and `enable_microservices` from the selected
profile. Do not rely on the values in `dev.tfvars` to override a pipeline profile.

## 7. Local Preflight

Run from the repository root. These checks do not create Azure resources:

```bash
terraform -chdir=infra init -backend=false -input=false
terraform -chdir=infra fmt -check -recursive
terraform -chdir=infra validate
python3 -m compileall -q notebooks microservices
python3 -m json.tool adf/exportedArmTemplate/ARMTemplateForFactory.json >/dev/null
python3 -m json.tool adf/exportedArmTemplate/ARMTemplateParametersFor-dev.json >/dev/null
bash -n scripts/*.sh
```

For the microservice:

```bash
docker build --file microservices/orders-api/Dockerfile --tag orders-api:ci microservices/orders-api
kubectl apply --dry-run=client -f microservices/orders-api/k8s/service.yml
```

A real deployment also requires the scans configured in the pipeline. Do not bypass the
SonarQube, Trivy, or Gitleaks gates for a shared branch.

## 8. Select a Deployment Profile

Set the root pipeline parameter `deploymentProfile`:

| Profile | Terraform foundation | ADF | Databricks | DABS | AKS/microservice |
|---|---:|---:|---:|---:|---:|
| `ADF_ONLY` | ADF, storage, network | Yes | No | No | No |
| `ADF_DATABRICKS` | ADF and Databricks | Yes | Classic | No | No |
| `DATABRICKS_DABS` | Databricks foundation | No | No | Yes | No |
| `MICROSERVICES_ONLY` | Disabled for this phase | No | No | No | No |
| `FULL_PLATFORM` | Disabled for this phase | No | No | No | No |

Start with `ADF_ONLY` to prove Azure access and the ARM export. Use
`DATABRICKS_DABS` when the bundle is the source of truth for Databricks jobs. Do not use
both classic notebook deployment and DABS for the same job in one run.

## 9. Azure DevOps Pipeline Execution

1. Import [azure-pipelines.yml](azure-pipelines.yml) as an existing YAML pipeline.
2. Confirm the repository branch trigger is `dev` and the PR target is `dev`.
3. Set `projectName` to `dataplatform` unless a matching project folder is added under
   `projects/`.
4. Select one `deploymentProfile`.
5. Run the pipeline or merge an approved pull request into `dev`.
6. Confirm `Unit_Testing`, `Code_Quality`, `Build_Validation`, and `Vulnerability_Scan` pass.
7. Confirm the immutable `build-artifact` contains the Terraform, ADF, notebook, DABS,
   microservice, and script directories.
8. Confirm `Deploy_dev` runs only after the scan stage and only on `dev`.
9. Confirm `Test_dev` lists the expected resources in `NA_ResourceRG`.

The deployment stage performs these commands in order:

```text
validate-config.sh
terraform init
terraform plan
terraform apply
Deploy ADF ARM export, when selected
Deploy DABS or classic Databricks notebooks/jobs, when selected
Build and deploy orders-api to ACR/AKS, when selected
List deployed Azure resources
```

Terraform uses the backend key `dataplatform-dev.tfstate`. Never run two applies against
this state at the same time; the pipeline disables concurrent work through its deployment
stage and the state backend provides locking.

## 10. ADF Deployment Details

The committed export is:

- Template: `adf/exportedArmTemplate/ARMTemplateForFactory.json`
- Parameters: `adf/exportedArmTemplate/ARMTemplateParametersFor-dev.json`

The parameter file currently targets `adf-dataplatform-dev` and disables public network
access. If the ADF factory name changes, update the parameter file and the Terraform
name together. The deployment script validates the ARM template before creating it and
fails if either file is missing.

An ARM factory resource alone does not prove that pipelines, datasets, linked services,
or triggers are usable. After deployment, open ADF Studio from a network-connected
machine, validate linked services, and run a test trigger. Private endpoints require DNS
resolution from the test machine.

## 11. Databricks Notebook and DABS Deployment

### Classic notebook/job profile

`FULL_PLATFORM` and `ADF_DATABRICKS` call `scripts/deploy-databricks.sh`:

1. Import `notebooks/` into `/Shared/dev`.
2. Reset the job only when both `databricks/job_id_dev.txt` and
   `databricks/job_spec_dev.json` exist in the artifact.
3. Leave job creation to the project team when no job specification is committed.

The CLI identity must have workspace permission to import notebooks and manage jobs.

### DABS profile

`DATABRICKS_DABS` runs from `dabs/`:

```bash
export DATABRICKS_HOST="https://<workspace-host>"
export DATABRICKS_CLIENT_ID="<client-id>"
export DATABRICKS_CLIENT_SECRET="<client-secret>"
databricks bundle validate -t dev
databricks bundle deploy -t dev
```

The bundle target is `dev`, the catalog variable is `dataplatform_dev`, and the job is
in [dabs/resources/jobs.yml](dabs/resources/jobs.yml). The Databricks service principal
must be able to access the workspace and the Unity Catalog catalog/schema objects created
by Terraform.

After deployment, verify the job exists and run it once. Confirm `01_ingest_raw.py` can
write to the `raw` area and `02_transform_silver.py` can read raw data and write silver
data. The private ADLS endpoints require the workspace network and DNS configuration to
be functional.

## 12. Microservice Deployment

Microservice deployment is disabled for this phase. ACR and AKS remain in the repository
for later activation, but are not created by the active profiles.

1. Build `microservices/orders-api` in ACR with a unique build ID tag.
2. Get AKS credentials for `AKS-NAME`.
3. Substitute the image tag and environment in the Kubernetes deployment manifest.
4. Apply the manifest.
5. Wait for `deployment/orders-api` to roll out.

Verify with:

```bash
kubectl get pods --namespace dev
kubectl rollout status deployment/orders-api --timeout=180s
kubectl get service orders-api --namespace dev
```

The private cluster requires the agent to have network access to the AKS private API and
DNS. The AKS kubelet also needs `AcrPull` on the registry. Terraform creates that role
only when `manage_access_control = true`; otherwise an administrator must grant it.

## 13. Verification Checklist

A deployment is complete only when all applicable checks pass:

- Terraform plan and apply finish without an out-of-band resource change.
- ADF ARM validation and deployment succeed.
- Databricks workspace URL, catalog, schemas, and selected job are reachable.
- Notebook execution writes expected raw and silver data.
- ACR contains the image tagged with the build ID.
- AKS pods are Ready and the rollout is complete.
- `az resource list --resource-group NA_ResourceRG` contains only expected resources.
- No high or critical Trivy findings or Gitleaks findings remain.

## 14. Recovery and Troubleshooting

- **Backend initialization fails:** confirm the storage account/container names, Azure
  login tenant, and `Storage Blob Data Contributor` access to the container.
- **Terraform role assignment fails:** set `manage_access_control = false` only when an
  administrator will create the missing assignments, then apply those assignments before
  running workloads.
- **Databricks authentication fails:** verify the workspace URL, client ID, secret,
  account ID, private DNS, and workspace reachability from the agent.
- **ADF deployment fails:** inspect the ARM validation output and confirm the factory name
  in the parameter file matches Terraform.
- **ACR push or AKS pull fails:** verify `AcrPush` for the agent and `AcrPull` for the
  AKS kubelet; check private endpoint DNS.
- **AKS rollout hangs:** run `kubectl describe pod` and inspect image pull, subnet, and
  private API connectivity errors.
- **A deployment is interrupted:** do not delete the state file. Re-run the same profile
  after checking the failed resource and the Terraform plan.

Never use `terraform destroy` against this shared development state without an approved
recovery plan. The state backend is intentionally retained outside the workload resources.
