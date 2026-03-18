# Copilot Instructions — Model Hunter

## Project Purpose

Model Hunter discovers all deployed Azure AI Foundry and OpenAI models across Azure subscriptions, correlates them with cost data, and generates reports for Azure administrators. It answers: **what models are deployed, where, and are they being used?**

The tool runs as an Azure Automation Runbook on a schedule, scanning multiple subscriptions via Managed Identity, and uploads CSV + HTML reports to Azure Blob Storage.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  Terraform (azapi provider only)                                     │
│  infra/ → provisions all Azure resources                             │
│                                                                      │
│  ┌──────────────┐  ┌─────────────────┐  ┌────────────────────────┐   │
│  │ Resource     │  │ Automation      │  │ Storage Account        │   │
│  │ Group        │──│ Account         │  │ + Blob Container       │   │
│  │              │  │ (SystemAssigned │  │ (model-discovery-      │   │
│  │              │  │  Managed ID)    │  │  reports)              │   │
│  └──────────────┘  └───────┬────────┘  └──────────┬─────────────┘   │
│                            │                      │                  │
│  ┌─────────────────────────┼──────────────────────┼──────────────┐   │
│  │ Role Assignments (on Managed Identity)         │              │   │
│  │  • Reader ──────────────────────► target subs  │              │   │
│  │  • Cost Management Reader ──────► target subs  │              │   │
│  │  • Storage Blob Data Contributor ──────────────┘              │   │
│  └───────────────────────────────────────────────────────────────┘   │
│                            │                                         │
│  ┌─────────────────────────┘                                         │
│  │ Runbook (PowerShell 7.4, source: src/ModelHunter.ps1)                    │
│  └───────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────┘

                    Runbook execution flow:

 ┌──────────────┐    ┌───────────────────┐    ┌──────────────────┐
 │ 1. Authenticate   │ 2. Discover        │    │ 3. Query Costs   │
 │ Connect-AzAccount │ Search-AzGraph     │    │ Cost Mgmt API    │
 │ -Identity    │───►│ cognitiveservices/ │───►│ Last 3 billing   │
 │              │    │ accounts/          │    │ periods          │
 │              │    │ deployments        │    │                  │
 └──────────────┘    └───────────────────┘    └────────┬─────────┘
                                                       │
                     ┌───────────────────┐    ┌────────▼─────────┐
                     │ 5. Upload         │    │ 4. Build Report  │
                     │ Publish-Report    │◄───│ CSV + HTML       │
                     │ → Blob Storage    │    │ with cost data   │
                     └───────────────────┘    └──────────────────┘
```

### Data flow between components

1. **`ModelHunter.ps1`** authenticates via Managed Identity, then calls each function in sequence, passing data forward.
2. **`Get-ModelDeployments`** returns an array of deployment objects (PSCustomObject) with all parsed fields. This array is the primary data structure passed through the pipeline.
3. **`Get-DeploymentCosts`** receives the subscription IDs, queries Cost Management, and returns a hashtable keyed by resource ID with cost-per-billing-period values.
4. **`Build-Report`** receives both the deployments array and the cost hashtable, merges them into a unified dataset, and produces CSV and HTML strings/files.
5. **`Publish-Report`** receives the file paths and uploads to the configured blob container.

## Resource Classification

### How resource IDs are parsed

Azure Cognitive Services deployment resource IDs follow these patterns:

**Foundry with Project:**
```
/subscriptions/{subId}/resourceGroups/{rgName}/providers/Microsoft.CognitiveServices/accounts/{resourceName}/projects/{projectName}/deployments/{deploymentName}
```

**Foundry Hub/Legacy (no project):**
```
/subscriptions/{subId}/resourceGroups/{rgName}/providers/Microsoft.CognitiveServices/accounts/{resourceName}/deployments/{deploymentName}
```

**OpenAI Service (no project):**
```
/subscriptions/{subId}/resourceGroups/{rgName}/providers/Microsoft.CognitiveServices/accounts/{resourceName}/deployments/{deploymentName}
```

### Classification rules (in order)
1. Check the account's `kind` property from the Resource Graph result
2. If `kind` equals `"OpenAI"` → classify as **OpenAI Service**, label the account as "OpenAI Resource Name"
3. If the resource ID contains `/projects/` segment → classify as **Foundry (Project)**, extract project name
4. Otherwise → classify as **Foundry (Hub/Legacy)**, project name is null

### Fields extracted per deployment
| Field | Source | Notes |
|-------|--------|-------|
| SubscriptionId | Resource ID segment | Resolved to name via `Get-AzSubscription` |
| SubscriptionName | `Get-AzSubscription` | Cached per subscription to avoid repeat calls |
| ResourceGroupName | Resource ID segment | |
| ResourceType | Classification logic | "OpenAI Service", "Foundry (Project)", "Foundry (Hub/Legacy)" |
| ResourceName | Resource ID segment | Foundry resource name or OpenAI resource name |
| ProjectName | Resource ID segment | Null for Hub/Legacy and OpenAI |
| DeploymentName | Resource ID segment | |
| ModelName | `properties.model.name` | From Resource Graph |
| ModelVersion | `properties.model.version` | From Resource Graph |
| SKU | `sku.name` | e.g., "Standard", "GlobalStandard", "ProvisionedManaged" |
| Capacity | `sku.capacity` | Provisioned TPM/units |

## Cost Analysis

### Billing period approach
Instead of rolling date ranges, we use Azure billing periods to align with how finance teams track spend:

1. Call `Get-AzBillingPeriod -MaxCount 3` to retrieve the 3 most recent billing periods
2. Each billing period has a `Name` (e.g., "202503"), `BillingPeriodStartDate`, and `BillingPeriodEndDate`
3. For each billing period, query the Cost Management API scoped to each target subscription

### Cost Management query
- Use `Invoke-AzCostManagementQuery` with:
  - **Type**: `ActualCost`
  - **Timeframe**: `Custom` with start/end from billing period
  - **Dataset grouping**: by `ResourceId` and `ServiceName`
  - **Filter**: `ServiceName` in (`"Azure AI Foundry Models"`, `"Azure OpenAI Service"`) — exact values may need validation at runtime
- Cost results are joined to deployments by matching the resource ID (account-level) from cost data to the deployment's parent account resource ID

### Usage determination
- A deployment is considered **"In Use"** if its parent account has **any non-zero cost** across the queried billing periods
- The report includes per-period cost columns so admins can see trends (increasing, decreasing, newly idle)

## Commands

### Terraform
```bash
cd infra/
terraform init                                    # Initialize providers + modules
terraform validate                                # Lint / syntax check
terraform fmt -recursive                          # Format all .tf files
terraform plan                                    # Preview all changes
terraform apply                                   # Deploy infrastructure
terraform plan -target=module.runbook             # Plan a single module
terraform destroy -target=module.role_assignments  # Destroy a single module
```

### PowerShell (local testing)
```powershell
# Authenticate interactively first
Connect-AzAccount

# Run locally (reports saved to ./output/)
./src/ModelHunter.ps1 -SubscriptionIds @("sub-id-1","sub-id-2")

# Run with blob upload
./src/ModelHunter.ps1 -SubscriptionIds @("sub-id-1","sub-id-2") `
  -StorageAccountResourceId "/subscriptions/.../storageAccounts/myaccount"

# Or dot-source to test individual functions
. ./src/ModelHunter.ps1
$deployments = Get-ModelDeployments -SubscriptionIds @("sub-id-1")
$costs = Get-DeploymentCosts -SubscriptionIds @("sub-id-1")
```

When `-StorageAccountResourceId` is omitted, reports are saved locally to `./output/` (gitignored). When provided, reports upload to Azure Blob Storage.

## Conventions

### Terraform

- **azapi provider only** — do not use azurerm. All resources use `azapi_resource` or `azapi_update_resource`.
- **One module per resource type** in `infra/modules/`. Each module has exactly three files: `main.tf`, `variables.tf`, `outputs.tf`.
- **API version pinning**: Every `azapi_resource` must specify an explicit, stable API version (e.g., `@2023-11-01`). Do not use preview API versions unless a feature is only available in preview.
- **Root module orchestration**: `infra/main.tf` only calls modules and wires outputs to inputs — no direct `azapi_resource` definitions in root.
- **Naming**: Module names use kebab-case (e.g., `role-assignments`). Resource names within modules use snake_case (e.g., `automation_account`).
- **Variable passthrough**: Modules accept only the variables they need. Use root-level `variables.tf` for user-facing config, pass specific values to modules.

### PowerShell

- **PowerShell 7.4 compatibility** — all scripts must run in the Azure Automation PowerShell 7.2+ runtime. Do not use features from 7.5+.
- **`src/ModelHunter.ps1` is a single Runbook script** with functions defined inline using `#region` blocks. One file = one Runbook deployment.
- **Function structure**: Each function within `ModelHunter.ps1` is self-contained. The `#region Main Execution` block at the bottom calls them in sequence.
- **Parameters**: Use `[CmdletBinding()]` and typed parameters with `[Parameter(Mandatory)]` where appropriate. Validate with `[ValidateNotNullOrEmpty()]`.
- **Error handling**: Use `try/catch` blocks. On fatal errors, use `throw` to propagate. On non-fatal errors (e.g., one subscription fails), log with `Write-Warning` and continue.
- **Logging**: Use `Write-Host` inside functions (avoids polluting return values — in PS 7+ Write-Host writes to Information stream, captured in Automation logs). Use `Write-Output` only in the main execution block. Use `Write-Warning` for non-fatal errors.
- **No hardcoded values**: All configuration (subscription IDs, storage account, container name) comes from parameters.
- **Authentication pattern**: The `#region Authentication` block handles `Connect-AzAccount -Identity` once. Functions assume they're already authenticated.

### Reference linking (REQUIRED)

Every time a PowerShell module or Terraform azapi resource type is used, include a comment with the official MS Learn documentation link. This applies to both code and documentation files.

**PowerShell example:**
```powershell
# https://learn.microsoft.com/powershell/module/az.resourcegraph/search-azgraph
$results = Search-AzGraph -Query $query -Subscription $subscriptionIds
```

**Terraform example:**
```hcl
# https://learn.microsoft.com/azure/templates/microsoft.automation/automationaccounts
resource "azapi_resource" "automation_account" {
  type = "Microsoft.Automation/automationAccounts@2023-11-01"
  # ...
}
```

### Documentation update rules

Keep docs in sync with code changes:

- **Terraform provider version changes** → update `docs/architecture.md` and affected module docs
- **Architecture changes** (new modules, new resources, flow changes) → update `docs/architecture.md` Mermaid diagram
- **PowerShell module additions/changes** → update `docs/runbook-process.md`
- **New parameters or config changes** → update `README.md` and `terraform.tfvars.sample`
- **New resource types or classification changes** → update the Resource Classification section above

### Local-first development workflow (REQUIRED)

**Never use the Azure Automation Runbook or `terraform apply` as your testing environment.** All `.ps1` and `.tf` changes must be validated locally before deployment:

**Development cycle:**
1. Make changes locally
2. Validate and test locally (see commands below)
3. Only after local validation passes → commit, push, and deploy

**Terraform — validate before apply:**
```bash
cd infra/
terraform fmt -recursive -check  # Verify formatting
terraform validate                # Syntax and config validation
terraform plan                    # Review planned changes — do NOT apply without reviewing plan output
```
Do not run `terraform apply` until `validate` and `plan` succeed and the plan output has been reviewed.

**PowerShell — run locally before deploying to Runbook:**
```powershell
# Authenticate interactively
Connect-AzAccount

# Execute the full pipeline in a local PowerShell 7.4+ session
./src/ModelHunter.ps1 -SubscriptionIds @("dev-sub-id") `
  -StorageAccountResourceId "/subscriptions/.../storageAccounts/..." `
  -ContainerName "model-discovery-reports"
```
Do not update the Runbook source in Azure until the script has been executed successfully in a local PowerShell 7.4+ session. The Runbook is a deployment target, not a test environment.
