# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A "plug-and-play" CI/CD framework for a data platform, deliberately scoped to **one
environment only** — `dev` — deployed into an existing Azure subscription
(`SyrenPAYGSubscription`) and an existing resource group (`NA_ResourceRG`). There is no
Stage/Prod environment and no environment promotion. The same pipeline logic runs through
either Azure DevOps (`azure-pipelines.yml`) or Jenkins (`Jenkinsfile`).

It deploys three kinds of workload from one repo, gated by a single `deploymentProfile`
parameter:
1. **Azure Data Factory** via incremental ARM template deployment (`adf/`).
2. **Azure Databricks** — either classic notebook/job import or a Databricks Asset Bundle
   (`notebooks/`, `dabs/`).
3. **`orders-api` microservice** to ACR/AKS (`microservices/orders-api/`).

Terraform (`infra/`) provisions the shared Azure foundation these workloads land on:
private VNet/subnets/NSGs/private DNS, private Key Vault (RBAC), private ADLS Gen2 (`raw`
and `silver` filesystems, OAuth-only), the ADF factory resource itself, and — conditionally
— the Databricks workspace (Unity Catalog) and ACR/AKS.

Read `README.md` for the full operational picture (Azure DevOps/Jenkins setup, variable
groups, service connections, verification checklists, troubleshooting) and `README_dev.md`
for the step-by-step deployment runbook. Both are long and authoritative — treat them as
source of truth over paraphrasing here.

## Hard constraint: this is Dev-only, on purpose

Several places actively enforce single-environment scope. **Do not casually work around
these** — if a task requires a second environment, see "Extending to a second environment"
below and do it deliberately.

- `infra/variables.tf`: `environment` variable validation rejects anything but `"dev"`.
- `infra/data.tf` / `infra/main.tf`: resource names are hardcoded/derived for `dev`
  (e.g. `stdataplatformsyrendev01`, `adf-dataplatform-syrendev01`).
- `scripts/validate-config.sh`: rejects any environment argument other than `dev`.
- `azure-pipelines.yml` / `Jenkinsfile`: only the `dev` branch triggers a deploy; PRs into
  `dev` only validate.
- `infra/governance.tf`: budgets, alerts, diagnostics, Log Analytics, and Databricks cost
  policies are commented out (`DEFERRED UNTIL DEV FUNCTIONAL TESTING IS COMPLETE`) —
  intentional, not an oversight.

## Deployment profiles

One pipeline parameter, `deploymentProfile`, selects which Terraform resources and which
deployment scripts run. This is the central branching point of the whole framework:

| Profile | Terraform Databricks | Terraform ACR/AKS | Runs |
|---|---:|---:|---|
| `FULL_PLATFORM` | Enabled | Enabled | Terraform, ADF ARM, Databricks notebooks/jobs, ACR build, AKS rollout |
| `ADF_DATABRICKS` | Enabled | Disabled | Terraform, ADF ARM, Databricks notebooks/jobs |
| `DATABRICKS_DABS` | Enabled | Disabled | Terraform, Databricks Asset Bundle deploy |
| `ADF_ONLY` | Disabled | Disabled | Terraform, ADF ARM deployment |
| `MICROSERVICES_ONLY` | Disabled | Enabled | Terraform, ACR build, AKS rollout |

`infra/variables.tf`'s `enable_databricks`/`enable_microservices` flags are set by the
pipeline from this profile (see `scripts/deploy-profile.sh` and `pipelines/templates/*`) —
don't rely on `dev.tfvars` values to control this; the pipeline overrides them.
`azure-pipelines.yml`'s current parameter `values:` list only exposes
`ADF_DATABRICKS`/`DATABRICKS_DABS`/`ADF_ONLY` even though `scripts/*` and Terraform support
all five — check which profiles are actually reachable through the pipeline before assuming
a profile is live end-to-end.

## Architecture / execution order

The dependency order across the whole system is intentional and enforced by pipeline stage
`dependsOn`, not just convention:

```
Terraform (foundation: network, Key Vault, ADLS, ADF resource, [Databricks], [ACR/AKS])
    -> ADF ARM deployment (factory must already exist)
    -> Databricks notebooks/jobs or DABS deploy (workspace must already exist)
    -> orders-api build (ACR) and rollout (AKS) (registry/cluster must already exist)
    -> smoke test (lists resources in NA_ResourceRG)
```

**Ownership boundary between Terraform and ADF ARM**: Terraform creates the Data Factory
resource (identity, managed VNet, `public_network_enabled = false`). Every ADF ARM
deployment afterward updates the *same* resource incrementally. ADF's exported ARM
template normally bakes `publicNetworkAccess` in as a literal snapshot rather than a
parameter, so a stale export can silently revert Terraform's networking setting. This repo
works around that by pinning `publicNetworkAccess` as an explicit ARM parameter in
`adf/exportedArmTemplate/ARMTemplateForFactory.json` /
`ARMTemplateParametersFor-dev.json`. When wiring up a real ADF Git integration, put
`adf/arm-template-parameters-definition.json` at the Git root ADF Studio publishes from
(**Manage > ARM template > Edit parameter configuration**) so future publishes keep
parameterizing it instead of reverting to a hardcoded literal.

**Databricks has two mutually exclusive deployment paths for the same jobs** — classic
(`scripts/deploy-databricks.sh`, imports `notebooks/` to `/Shared/dev`, resets a job only if
`databricks/job_id_dev.txt` + `databricks/job_spec_dev.json` exist) vs. DABS
(`databricks bundle validate/deploy -t dev` against `dabs/`). Never run both for the same
job in one deployment.

**CI validation and CD deployment are decoupled by a build artifact.** `Build_Validation`
assembles `infra`, `adf`, `notebooks`, `dabs`, `microservices`, `projects`, `scripts` into
one immutable artifact stamped with the source commit ID; `Deploy_dev` consumes that
artifact rather than re-checking out source. Keep this in mind when changing what's copied
into the artifact (see the `cp -R` list in `Jenkinsfile` / `pipelines/templates/ci-build.yml`)
— a file left out of that list will validate in CI but not exist at deploy time.

## Directory map (non-obvious parts only)

- `infra/` — Terraform for the shared foundation. Split by concern:
  `main.tf` (Key Vault, ADF, Databricks workspace, ACR, AKS + core role assignments),
  `data.tf` (storage account, ADLS filesystems, Databricks access connector),
  `network.tf`, `identity.tf`, `unity_catalog.tf`, `governance.tf` (mostly commented out —
  see Dev-only constraint above), `variables.tf`. `environments/dev/` holds the only
  supported backend/tfvars pair.
- `adf/exportedArmTemplate/` — the committed ADF publish output. Replace with real project
  exports; the factory name in the parameters file must match Terraform's.
- `dabs/` — Databricks Asset Bundle (`databricks.yml`, `resources/jobs.yml`), single `dev`
  target, catalog variable `dataplatform_dev`.
- `notebooks/` — `01_ingest_raw.py` (raw ADLS ingest), `02_transform_silver.py`
  (raw -> silver transform); deployed via the classic Databricks path.
- `microservices/orders-api/` — reference Flask service (`GET /`, `GET /healthz`),
  `Dockerfile`, `k8s/deployment.yml` + `service.yml` (templated with `__IMAGE__` /
  `__ENVIRONMENT__` placeholders, substituted at deploy time — not valid manifests as-is).
- `pipelines/templates/` — reusable Azure DevOps stage templates (`ci-unit-tests`,
  `ci-quality`, `ci-build`, `ci-vulnerability-scan`, `cd-data-pipeline`,
  `test-environment`) that `azure-pipelines.yml` composes. `Jenkinsfile` reimplements the
  same stage sequence natively rather than sharing these templates.
- `scripts/` — the actual deployment logic, called by both CI systems:
  `validate-config.sh` (preflight: required env vars/commands per profile),
  `deploy-profile.sh` (dispatches to the profile-specific scripts below),
  `deploy-adf.sh`, `deploy-databricks.sh`, `deploy-microservice.sh` (per-component deploy),
  `validate-microservice.sh` (Docker build check). `register-self-hosted-agent.sh` /
  `self-hosted-agent-cloud-init.sh` / `cleanup-agent-workspace.sh` manage the optional
  Terraform-provisioned self-hosted build agent VM (disabled by default).
- `projects/dataplatform/` — the one onboarded "project"; `onboarding.yml` documents the
  pattern for adding another project folder (see README "Onboarding Another Project").

## Common commands

Local validation (no Azure resources created) — run from the repo root:

```bash
terraform -chdir=infra fmt -check -recursive
terraform -chdir=infra init -backend=false -input=false
terraform -chdir=infra validate
python -m unittest discover -s tests -v      # no tests/ committed yet — add test_*.py before relying on this
python -m compileall -q notebooks microservices
python -m py_compile microservices/orders-api/app.py
bash -n scripts/*.sh
docker build -t orders-api:local microservices/orders-api
```

Render-check the Kubernetes manifest (it has `__IMAGE__`/`__ENVIRONMENT__` placeholders, so
`kubectl apply -f` directly on it will not work):

```bash
sed -e 's|__IMAGE__|orders-api:local|g' -e 's|__ENVIRONMENT__|dev|g' \
  microservices/orders-api/k8s/deployment.yml | kubectl apply --dry-run=client -f -
```

On Windows, run the Bash scripts from Git Bash or WSL; Terraform/Python can run from
PowerShell if installed there.

Actual Dev deployment (requires a network-connected runner and real credentials — do not
run casually):

```bash
terraform -chdir=infra init -backend-config=environments/dev/backend.tfvars -input=false
terraform -chdir=infra plan -var-file=environments/dev/dev.tfvars -out=dev.tfplan
terraform -chdir=infra apply -input=false dev.tfplan
./scripts/validate-config.sh dev <PROFILE>
./scripts/deploy-profile.sh dev <PROFILE> <artifact-dir>
```

Never run `terraform destroy` against the shared Dev state, and never run two `apply`s
concurrently (the state backend locks, but the pipeline also serializes `Deploy_dev`).

## Security constraints that matter for changes here

- Never commit tokens, client secrets, passwords, Terraform state/plans, or `.env` files.
- Terraform state backend (storage account + `tfstate` container) is bootstrapped *outside*
  Terraform itself (`az storage account create`, not a resource block) specifically so
  Terraform can never destroy its own backend — don't "fix" this by moving it into `infra/`.
- Secrets (Databricks client secret, etc.) flow in only via Azure DevOps variable
  group secrets / Jenkins credentials / env vars (`TF_VAR_databricks_client_secret`, ...) —
  never hardcode them into `.tfvars` or scripts.
- The pipeline hard-blocks on SonarQube quality gate, Trivy HIGH/CRITICAL,
  Gitleaks findings, Terraform validation, and deployment smoke checks — don't add
  `--no-verify`-style bypasses to get a change through.

## Extending to a second environment

Deliberately not supported today. If asked to add Stage/Prod, all of the following need to
change together (see README "If This Framework Ever Needs a Second Environment"):
`infra/variables.tf` environment validation, hardcoded `dev`-named resources in
`infra/data.tf`/`infra/main.tf`, `scripts/validate-config.sh`, a new
`infra/environments/<name>/` backend/tfvars pair with a distinct state key, and new pipeline
stage(s) with their own service connection/credential and variable group. Treat this as a
deliberate, reviewed change, not an incidental one.
