# Data Platform CI/CD Framework (Dev-Only)

> Scope: this framework deploys **one environment only** — `dev` — into the existing
> subscription **SyrenPAYGSubscription** (`d5691146-731e-4c08-92d4-b0b2703db592`) and the
> existing resource group **`NA_ResourceRG`**. There is no Stage or Production environment,
> no second resource group, and no branch-based promotion between environments. Azure
> budgets, alerts, cost-attribution tags, diagnostics, Log Analytics, and Databricks cost
> policies are intentionally deferred (see `infra/governance.tf`) until core Dev functional
> testing is complete; they are not tied to any future Stage/Prod rollout.

A Continuous Integration and Continuous Delivery framework for Azure Data Factory, Azure
Databricks, Databricks Asset Bundles, and containerized microservices, targeting a single
Dev environment. The same repository can run through Azure DevOps or Jenkins.

## What This Repository Deploys

1. Azure Data Factory through an ARM template.
2. Azure Databricks notebooks and jobs, or a Databricks Asset Bundle.
3. The `orders-api` microservice to Azure Container Registry and Azure Kubernetes Service.

Terraform creates and manages the Azure foundation inside `NA_ResourceRG`:

- Key Vault (private, RBAC-authorized)
- Azure Data Factory (managed virtual network, public network access disabled)
- ADLS Gen2 (`raw` and `silver` filesystems, private endpoints, OAuth-only access)
- Virtual network, subnets, NSGs, and private DNS zones for all of the above
- Azure Databricks workspace, Premium SKU, VNet-injected, Unity Catalog metastore/catalog/schemas — when Databricks is enabled
- Azure Container Registry and a private Azure Kubernetes Service cluster — when microservices are enabled
- Entra groups (and optional Terraform-managed test users) with group-based Azure and Databricks RBAC

`NA_ResourceRG` is an **existing** resource group (referenced via a Terraform data source,
not created by this framework). Terraform never creates or references any other resource
group, subscription, or environment name.

## Branch Rules

Use exactly one deployment branch: `dev`.

| Branch | Target | What happens |
|---|---|---|
| `dev` | Development (`NA_ResourceRG`) | Validation, then deploy, then run the Development smoke test. |

Feature branch workflow:

1. Create a feature branch from `dev`, for example `feature/add-orders-filter`.
2. Make and test your changes on the feature branch.
3. Open a pull request from the feature branch into `dev`.
4. The pull request runs validation only; it does not deploy to Azure.
5. After approval and merge, the `dev` branch pipeline deploys Development.

There is no `uat` or `main` deployment branch, no Stage/Production Terraform environment,
and no multi-environment promotion. Do not add other deployment branches without first
extending `infra/` to support them (see "If This Framework Ever Needs a Second Environment"
below).

## Architecture

```text
Git push or pull request
    |
    v
CI validation, Terraform validation, security scan, artifact assembly
    |
    v
One immutable build artifact
    |
    v
Development (NA_ResourceRG): Terraform -> ADF -> Databricks -> ACR/AKS
    |
    v
Development smoke test
```

Pull requests run validation and scanning only. A push to `dev` creates one artifact and
deploys it to `NA_ResourceRG`.

## Deployment Profiles

The root pipeline parameter is `deploymentProfile`. Select exactly one value:

| Profile | Deploys | Terraform Databricks | Terraform ACR/AKS |
|---|---|---:|---:|
| `FULL_PLATFORM` | Terraform, ADF ARM, Databricks CLI notebooks/jobs, ACR build, and AKS rollout | Enabled | Enabled |
| `ADF_DATABRICKS` | Terraform, ADF ARM, and Databricks CLI notebooks/jobs | Enabled | Disabled |
| `DATABRICKS_DABS` | Terraform and Databricks Asset Bundle deploy | Enabled | Disabled |
| `ADF_ONLY` | Terraform and ADF ARM deployment | Disabled | Disabled |
| `MICROSERVICES_ONLY` | Terraform, ACR build, and AKS rollout | Disabled | Enabled |

The default is `FULL_PLATFORM`. For a first safe demonstration, use `ADF_ONLY` if the ADF
export is valid and no Databricks or AKS deployment is needed.

## Prerequisites

1. Access to subscription `d5691146-731e-4c08-92d4-b0b2703db592` (SyrenPAYGSubscription)
   and its tenant, with permission to create networking, private endpoints, Storage, Key
   Vault, ADF, Databricks, AKS, RBAC, and Entra objects inside `NA_ResourceRG`. `Contributor`
   on `NA_ResourceRG` alone is **not** sufficient for role assignments, Terraform state
   data-plane access, or Entra/Databricks account administration — grant those separately
   to the deployment identity.
2. Terraform 1.7+, Azure CLI 2.60+, Databricks unified CLI 0.220+, Python 3.12, Node.js 18
   LTS, Docker 24+, kubectl, and Bash on the Azure DevOps self-hosted agent (or Jenkins
   agent with label `azure-data-platform`).
3. A pre-existing Terraform state storage account and `tfstate` container inside
   `NA_ResourceRG` (no separate resource group), matching
   `infra/environments/dev/backend.tfvars`.
4. A Databricks account service principal with account-level permission to create or
   manage the Unity Catalog metastore and workspace assignment.
5. Azure DevOps service connection `svc-dataplatform-dev`, variable group
   `vg-dataplatform-dev`, and environment `dev`. (Or, for Jenkins, credential
   `azure-sp-dataplatform-dev`.)
6. A VNet-capable Azure region and subscription quota for private endpoints, AKS, and
   Databricks.

Private-only services require the deployment agent (or a connected runner) to resolve and
reach the private DNS names from the VNet. A public hosted agent cannot deploy or test
private Databricks/ADF/AKS endpoints without a network path.

## Self-Hosted Agent Toolchain

The pipeline uses an Azure DevOps self-hosted agent pool named `azure-data-platform`
(Jenkins: an agent with the same label). Install and pin the following tools on that image.

| Tool | Minimum | Purpose |
|---|---:|---|
| OpenTofu | 1.7 | Infrastructure, Terraform-compatible CLI |
| Azure CLI | 2.60 | Azure, ARM, ACR, and AKS |
| Databricks unified CLI | 0.220 | Databricks and DABs |
| Python | 3.12 | Notebook and service checks |
| Node.js | 18 LTS | ADF tooling compatibility |
| Docker | 24 | Container build and validation |
| kubectl | Current | AKS rollout |
| SonarQube Scanner | 5+ | Static analysis, code smells, bugs, and coverage gate |
| Trivy | 0.50 | Post-image-build filesystem and container vulnerability scan |
| Gitleaks | 8+ | Secret detection before artifact promotion |
| tflint | Current | Terraform linting (optional; skipped if not installed) |
| Checkov | Current | Terraform security policies (optional; skipped if not installed) |

Required platform integrations: SonarQube server, Azure Key Vault for runtime secrets,
Azure Monitor/Log Analytics (once enabled — see the governance note above), and Microsoft
Defender for Cloud.

The pipeline blocks on SonarQube quality gate, Trivy HIGH/CRITICAL findings, Gitleaks
findings, Terraform validation, and failed deployment smoke checks.

## Terraform State Bootstrap

This framework has access to exactly one resource group, `NA_ResourceRG`, so the Terraform
state storage account lives there too — not in a separate resource group. Create it once,
outside the application state that Terraform itself manages:

```text
Resource group:  NA_ResourceRG (existing — do not create a new one)
Storage account: sttfstatedatadev1
Container:       tfstate
Blob versioning: enabled
```

The storage account is created directly with `az storage account create`, outside of
Terraform, so Terraform never manages or can destroy its own state backend. Grant the
pipeline identity `Storage Blob Data Contributor` scoped to the `tfstate` container. The
state key is `dataplatform-dev.tfstate` (`infra/environments/dev/backend.tfvars`). If the
storage account name changes, update that file.

## Azure DevOps Configuration

### Service Connection

Create one Azure Resource Manager connection using **Workload Identity Federation**:

```text
svc-dataplatform-dev
```

Permissions: `Contributor` on `NA_ResourceRG`, `Storage Blob Data Contributor` on the
Terraform state container, `Key Vault Secrets User` on the Dev Key Vault, `AcrPush` on ACR
(when microservices are enabled), and `Azure Kubernetes Service Cluster User Role` on AKS.

### Variable Groups

```text
vg-dataplatform-shared
vg-dataplatform-dev
```

| Variable | Secret | Purpose |
|---|---:|---|
| `ARM-SUBSCRIPTION-ID` | No | `d5691146-731e-4c08-92d4-b0b2703db592` |
| `ARM-TENANT-ID` | No | Azure tenant |
| `ARM-CLIENT-ID` | No | Workload identity client |
| `RESOURCE-GROUP-NAME` | No | `NA_ResourceRG` |
| `DATABRICKS-HOST` | No | Workspace URL |
| `DATABRICKS-ACCOUNT-ID` | No | Databricks account ID for Unity Catalog administration |
| `DATABRICKS-CLIENT-ID` | Yes | Databricks service principal |
| `DATABRICKS-CLIENT-SECRET` | Yes | Databricks service principal |
| `ACR-NAME` | No | `acrdataplatformdev` |
| `AKS-NAME` | No | `aks-dataplatform-dev` |

### Azure DevOps Environment

Create one Azure DevOps Environment named `dev`, permitting deployment from
`refs/heads/dev`. No manual approval is required — Dev deploys automatically after
vulnerability scanning passes.

### Create and Run the Pipeline

1. Push this repository to Azure Repos or a connected Git repository.
2. Open **Pipelines** and select **New pipeline**.
3. Select the repository and **Existing Azure Pipelines YAML file**.
4. Select `/azure-pipelines.yml` and save.
5. Confirm the service connection, variable groups, backend, and the `dev` environment exist.
6. Run manually or push to `dev`.

The root pipeline parameters are:

```yaml
projectName: dataplatform
deploymentProfile: FULL_PLATFORM
```

The Azure DevOps stage names are `Unit_Testing`, `Code_Quality`, `Build_Validation`,
`Vulnerability_Scan`, `Deploy_dev`, and `Test_dev`.

## Jenkins Configuration

Install Pipeline Declarative, Multibranch Pipeline, Credentials Binding, Azure Credentials,
Docker Pipeline, and SonarQube Scanner plugins. The agent must have label
`azure-data-platform` and must contain Terraform, Azure CLI, Databricks CLI, SonarQube
`sonar-scanner`, Trivy, Gitleaks, kubectl, and Docker.

Create one Azure credential:

```text
azure-sp-dataplatform-dev
```

Create a Databricks service-principal credential as a Jenkins username/password
credential (username = Databricks client ID, password = client secret):

```text
databricks-sp-dev
```

The Jenkins Azure identity needs `Contributor` on `NA_ResourceRG`, `Storage Blob Data
Contributor` on Terraform state, `AcrPush` on ACR, and `Azure Kubernetes Service Cluster
User Role` on AKS.

### Jenkins Parameters

| Parameter | Values | Purpose |
|---|---|---|
| `DEPLOYMENT_PROFILE` | `FULL_PLATFORM`, `ADF_DATABRICKS`, `DATABRICKS_DABS`, `ADF_ONLY`, `MICROSERVICES_ONLY` | Exact workload profile |
| `DATABRICKS_HOST_DEV` | Workspace URL | Required for Databricks profiles |
| `DATABRICKS_ACCOUNT_ID_DEV` | Account ID | Required for Unity Catalog profiles |

Create a Pipeline or Multibranch Pipeline connected to this repository using `Jenkinsfile`.
Jenkins runs validation for feature branches and pull requests, and runs `Deploy DEV` and
`Test DEV` only on the `dev` branch.

## Azure Pipeline Stage-by-Stage Execution

### Stage 1: `Unit_Testing`

Checks out the repository, selects Python 3.12, installs
`microservices/orders-api/requirements.txt`, runs unittest discovery over `tests/` when
test files are present, records `coverage.xml`, and compiles `notebooks` and
`microservices` with Python. This repository currently has no developer-owned tests under
`tests/`; add tests named `test_*.py` before relying on the coverage gate.

### Stage 2: `Code_Quality`

Checks Terraform formatting, runs `tflint`/Checkov when installed, runs SonarQube
analysis and publishes its quality gate, and runs the open-source Trivy scan. This stage
fails when a mandatory quality or security policy fails.

### Stage 3: `Build_Validation`

Selects Node.js 18, runs Terraform formatting/validation, optionally runs Checkov and
Trivy, builds the `orders-api` Docker image for validation, assembles `infra`, `adf`,
`notebooks`, `dabs`, `microservices`, `projects`, and `scripts` into one artifact, writes
the source commit ID to `build-id.txt`, and publishes it as `build-artifact`. The
deployment stage consumes this artifact instead of rebuilding the source.

### Stage 4: `Vulnerability_Scan`

Builds the `orders-api:scan` image, runs Trivy filesystem and image scanning (blocking on
HIGH/CRITICAL), and runs Gitleaks secret detection.

### Stage 5: `Deploy_dev`

Runs only when `Build.SourceBranch = refs/heads/dev` and `Build.Reason` is not
`PullRequest`. Downloads `build-artifact`, initializes Terraform with the Dev backend,
plans against `infra/environments/dev/dev.tfvars`, applies, deploys the selected ADF,
Databricks, or microservice components, and lists Azure resources for confirmation.

### Stage 6: `Test_dev`

Runs only after `Deploy_dev` on the `dev` branch. Confirms `NA_ResourceRG` exists and
lists its resources — a smoke check of Azure resource deployment, not a full application
integration test.

## Component Deployment Details

### Azure Data Factory

`scripts/deploy-adf.sh` deploys:

```text
adf/exportedArmTemplate/ARMTemplateForFactory.json
adf/exportedArmTemplate/ARMTemplateParametersFor-dev.json
```

using incremental ARM deployment. Replace the reference files with generated ADF publish
output containing the real factories, pipelines, datasets, linked services, triggers, and
integration runtimes.

**Ownership boundary with Terraform:** Terraform creates the Data Factory resource itself
(identity, managed virtual network, and `public_network_enabled = false`), and every ADF
ARM deployment updates the same resource incrementally afterward. By default, ADF's
generated ARM template bakes factory-level properties such as `publicNetworkAccess` into
the template as a literal snapshot of whatever the source factory had at export time, not
as a parameter — so a stale export can silently overwrite Terraform's networking setting on
the next publish. This repository pins `publicNetworkAccess` as an explicit ARM parameter
(see `ARMTemplateForFactory.json` and `ARMTemplateParametersFor-dev.json`) instead of
relying on the export snapshot. When you connect a real ADF instance via Git integration,
place `adf/arm-template-parameters-definition.json` at the Git integration root ADF Studio
is configured to read from (**Manage > ARM template > Edit parameter configuration**) so
future publishes keep parameterizing `publicNetworkAccess` rather than reverting to a
hardcoded literal.

### Azure Databricks

`FULL_PLATFORM` and `ADF_DATABRICKS` call `scripts/deploy-databricks.sh`, import notebooks
to `/Shared/dev`, and reset a job when matching job files exist.

`DATABRICKS_DABS` runs:

```bash
databricks bundle validate -t dev
databricks bundle deploy -t dev
```

The DAB contains a single `dev` target and receives its workspace URL through
`DATABRICKS_BUNDLE_VAR_workspace_host`.

### Microservices

The reference Flask service exposes `GET /` and `GET /healthz`.
`scripts/deploy-microservice.sh` performs:

```text
1. az acr build to build and push an immutable build-tagged image.
2. az aks get-credentials for the Dev cluster.
3. Substitute image and environment values into the Kubernetes manifest.
4. kubectl apply the Deployment and Service.
5. kubectl rollout status and fail if the rollout does not complete.
```

The image tag is Azure DevOps `Build.BuildId` or Jenkins `BUILD_NUMBER`.

## Security Requirements

- Never commit tokens, client secrets, passwords, Terraform state, plans, or `.env` files.
- Prefer Workload Identity Federation for Azure DevOps.
- Use managed identities and Key Vault references for application secrets.
- Enable Azure Storage blob versioning for Terraform state.
- Use branch policies requiring pull request review and successful build validation before
  merging into `dev`.
- Run Trivy against the repository and container image before every deployment.

## Local Validation

Run from the repository root:

```bash
terraform -chdir=infra fmt -check -recursive
terraform -chdir=infra init -backend=false -input=false
terraform -chdir=infra validate
python -m unittest discover -s tests -v
python -m compileall -q notebooks microservices
python -m py_compile microservices/orders-api/app.py
bash -n scripts/*.sh
docker build -t orders-api:local microservices/orders-api
```

Render-check the Kubernetes manifest without applying it:

```bash
sed -e 's|__IMAGE__|orders-api:local|g' -e 's|__ENVIRONMENT__|dev|g' microservices/orders-api/k8s/deployment.yml | kubectl apply --dry-run=client -f -
```

On Windows, run Bash commands from Git Bash or WSL. Run Terraform and Python from
PowerShell if those tools are installed there.

## Local Terraform Deployment (Dev Runner)

Run from the repository root through a network-connected Dev runner:

```bash
terraform -chdir=infra init -backend-config=environments/dev/backend.tfvars -input=false
terraform -chdir=infra fmt -check -recursive
terraform -chdir=infra validate
terraform -chdir=infra plan -var-file=environments/dev/dev.tfvars -out=dev.tfplan
terraform -chdir=infra apply -input=false dev.tfplan
```

Required runtime values: `ARM_SUBSCRIPTION_ID`, `ARM_TENANT_ID`, `ARM_CLIENT_ID`,
`TF_VAR_tenant_id`, `TF_VAR_databricks_host`, `TF_VAR_databricks_account_id`,
`TF_VAR_databricks_client_id`, and `TF_VAR_databricks_client_secret`. Supply these through
Azure DevOps secret variables or environment variables — never commit them. The Dev
subscription is pinned in `infra/environments/dev/dev.tfvars` and should match the Azure
service connection.

Optional identity inputs: `TF_VAR_dev_admin_object_ids`, `TF_VAR_dev_data_engineer_object_ids`,
`TF_VAR_dev_user_definitions` (sensitive; prefer enterprise identity lifecycle processes for
real users), and `TF_VAR_dev_group_members`.

## Post-Deployment Validation

1. Storage public access is disabled, ADLS `raw` and `silver` exist, and Databricks can
   read/write through the managed identity external location.
2. The Dev workspace is Premium, attached to the Dev metastore, and the catalog, schemas,
   grants, and restrictive cluster policy exist.
3. Private DNS records resolve from a VNet-connected runner for Storage, Key Vault, ACR,
   ADF, and Databricks.
4. Key Vault and Storage access works only through the intended managed identities and
   groups.
5. AKS is private, the orders API is reachable only through its intended internal service
   path, and the rollout succeeds.
6. Confirm that deferred budget, diagnostics, and cost-control resources remain disabled
   during core testing (see `infra/governance.tf`).
7. Entra memberships and Azure/Databricks grants match the declared inputs.

## Troubleshooting

### Terraform backend initialization fails

Confirm the state resource group, storage account, and `tfstate` container exist, the
pipeline identity has `Storage Blob Data Contributor`, and `infra/environments/dev/backend.tfvars`
has the correct names.

### Terraform validation fails

Run `terraform -chdir=infra fmt -recursive`, then `terraform -chdir=infra init -backend=false -input=false`,
then `terraform -chdir=infra validate`. Confirm Terraform is 1.7+ and all required
variables have values.

### ADF deployment fails

Confirm `ARMTemplateForFactory.json` is valid JSON, `ARMTemplateParametersFor-dev.json`
exists, `NA_ResourceRG` exists, and the service connection can deploy ARM resources.

### Databricks authentication fails

Confirm `DATABRICKS-HOST`, `DATABRICKS-CLIENT-ID`, `DATABRICKS-CLIENT-SECRET`, and
`DATABRICKS-ACCOUNT-ID` are present in `vg-dataplatform-dev` (or the matching Jenkins
parameters/credential), and that the service principal can access the workspace.

### ACR build or AKS rollout fails

Confirm `ACR-NAME` and `AKS-NAME`, that the identity has `AcrPush` and the AKS Cluster User
role, and that the AKS kubelet identity has `AcrPull`:

```bash
kubectl get pods
kubectl describe deployment orders-api
kubectl rollout status deployment/orders-api
```

### Pipeline validates but does not deploy

Confirm the run is not a Pull Request run, the source branch is exactly `refs/heads/dev`,
and the `Deploy_dev` stage dependency succeeded.

### Vulnerability scan fails

Read the exact Trivy finding, upgrade the affected dependency or base image, remove any
committed secrets reported by Gitleaks, rotate any exposed secret, and re-run locally
before pushing again.

## Onboarding Another Project

1. Add the project under `projects/{project-name}`.
2. Add non-secret Terraform values for `dev` only, targeting the same subscription and
   `NA_ResourceRG`, or a different existing resource group the project owns.
3. Add the ADF ARM export, Databricks notebooks/DAB, and microservice directories.
4. Create a matching Azure DevOps service connection and variable groups, or Jenkins
   credentials, for `dev`.
5. Update `projectName` and select the required deployment profile.
6. Run Development and validate.

No pipeline logic fork is required; only project assets, parameters, identities, and
environment configuration change.

## If This Framework Ever Needs a Second Environment

This framework intentionally supports Dev only right now: `infra/variables.tf` rejects any
`environment` value other than `dev`, `infra/data.tf` hardcodes the Dev storage account
name, and `scripts/validate-config.sh` rejects any other environment. Extending this to a
second environment (Stage, Prod, or otherwise) requires, at minimum:

1. Relaxing the `environment` variable validation in `infra/variables.tf`.
2. Parameterizing resource names in `infra/data.tf` (and anywhere else a name is hardcoded)
   by environment instead of literally `dev`.
3. Deciding whether the new environment uses a new resource group and/or subscription, and
   setting `resource_group_name`/`subscription_id` explicitly per environment so
   environments cannot collide.
4. Adding `infra/environments/<name>/backend.tfvars` and `<name>.tfvars` with a distinct
   Terraform state key.
5. Re-adding the corresponding deployment stage(s) to `azure-pipelines.yml`/`Jenkinsfile`,
   with their own service connection/credential, variable group, and (for anything beyond
   Dev) an approval gate.

Do this deliberately and test it in a sandbox before pointing it at anything shared.

## First-Deployment Checklist

```text
[ ] Azure subscription d5691146-731e-4c08-92d4-b0b2703db592 is available.
[ ] NA_ResourceRG exists and the deployment identity has the required roles.
[ ] Terraform state resource group, storage account, and container exist.
[ ] svc-dataplatform-dev (or azure-sp-dataplatform-dev for Jenkins) exists.
[ ] vg-dataplatform-shared and vg-dataplatform-dev are configured.
[ ] ADF ARM files are real project publish exports (or ADF_ONLY/ADF_DATABRICKS is skipped).
[ ] Databricks workspace URL and service principal are configured.
[ ] ACR and AKS names are configured for microservices.
[ ] Pipeline tools are installed on the agent.
[ ] Branch protection and pull request validation are enabled for dev.
[ ] No secrets are present in Git.
```

No credentials or subscription identifiers beyond the fixed Dev subscription ID are
committed by this framework. Runtime secrets must be supplied by Azure DevOps variable
groups, Azure workload identity, Jenkins credentials, or Key Vault.
