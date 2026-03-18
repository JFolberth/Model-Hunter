# Runbook Process

This document provides a detailed walkthrough of what the Model Hunter Runbook (`src/main.ps1`) does at each step.

## Step-by-Step Walkthrough

### 1. Authentication

The Runbook authenticates using the Automation Account's System-Assigned Managed Identity:

```powershell
# https://learn.microsoft.com/powershell/module/az.accounts/connect-azaccount
Connect-AzAccount -Identity -ErrorAction Stop
```

If authentication fails, the Runbook throws a fatal error and stops. All subsequent functions assume the session is already authenticated.

### 2. Discovery

The `Get-ModelDeployments` function queries Azure Resource Graph for all Cognitive Services accounts and their model deployments:

```powershell
# https://learn.microsoft.com/powershell/module/az.resourcegraph/search-azgraph
Search-AzGraph -Query $query -Subscription $SubscriptionIds
```

The Resource Graph query targets `microsoft.cognitiveservices/accounts` and joins with their `/deployments` sub-resources. Results include the account `kind`, deployment `properties.model.name`, `properties.model.version`, `sku.name`, and `sku.capacity`.

Subscription names are cached via `Get-AzSubscription` to avoid repeated lookups.

### 3. Resource ID Parsing and Classification

Each deployment's resource ID is parsed to extract subscription ID, resource group, account name, project name (if present), and deployment name. Deployments are classified into one of three types:

| Type | Condition | Example Resource ID |
|---|---|---|
| **OpenAI Service** | Account `kind` equals `"OpenAI"` | `/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.CognitiveServices/accounts/{name}/deployments/{dep}` |
| **Foundry (Project)** | Resource ID contains `/projects/` segment | `/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.CognitiveServices/accounts/{name}/projects/{project}/deployments/{dep}` |
| **Foundry (Hub/Legacy)** | Neither of the above | `/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.CognitiveServices/accounts/{name}/deployments/{dep}` |

Classification rules are evaluated in order:

1. Check the account's `kind` property from the Resource Graph result.
2. If `kind` equals `"OpenAI"` → **OpenAI Service**.
3. If the resource ID contains a `/projects/` segment → **Foundry (Project)**, and the project name is extracted.
4. Otherwise → **Foundry (Hub/Legacy)**, and project name is null.

### 4. Cost Analysis

The `Get-DeploymentCosts` function retrieves cost data for the last 3 billing periods:

1. **Get billing periods:**

   ```powershell
   # https://learn.microsoft.com/powershell/module/az.billing/get-azbillingperiod
   Get-AzBillingPeriod -MaxCount 3
   ```

   Each billing period has a `Name` (e.g., `"202503"`), `BillingPeriodStartDate`, and `BillingPeriodEndDate`.

2. **Query costs per subscription per period:**

   ```powershell
   # https://learn.microsoft.com/powershell/module/az.costmanagement/invoke-azcostmanagementquery
   Invoke-AzCostManagementQuery `
       -Scope "/subscriptions/$subId" `
       -Type 'ActualCost' `
       -Timeframe 'Custom' `
       -TimePeriod $timePeriod `
       -DatasetGranularity 'None' `
       -DatasetGrouping @($groupByResourceId, $groupByServiceName) `
       -DatasetFilter $filterDimension
   ```

   The filter restricts results to `ServiceName` in (`"Azure AI Foundry Models"`, `"Azure OpenAI Service"`).

3. **Normalize resource IDs:** Cost results are keyed at the account level by stripping `/deployments/...` and `/projects/...` segments, then lowercased for consistent matching.

If billing periods or cost queries fail, the Runbook logs a warning and continues with empty cost data rather than stopping.

### 5. Report Generation

The `Build-Report` function merges deployments with cost data and produces two outputs:

- **CSV** — generated via `ConvertTo-Csv -NoTypeInformation`
- **HTML** — a styled table with conditional row formatting

### 6. Upload

The `Publish-Report` function uploads both reports to Azure Blob Storage:

```powershell
# https://learn.microsoft.com/powershell/module/az.storage/set-azstorageblobcontent
Set-AzStorageBlobContent -File $tempCsvPath -Container $ContainerName `
    -Blob "model-discovery-$timestamp.csv" -Context $storageContext
```

Files are named with a timestamp (e.g., `model-discovery-2025-01-15-143022.csv`). Temporary files are cleaned up after upload.

## Resource Classification Rules

| Rule | Type Assigned | Project Name |
|---|---|---|
| Account `kind` = `"OpenAI"` | OpenAI Service | N/A |
| Resource ID contains `/projects/{name}/` | Foundry (Project) | Extracted from ID |
| All other Cognitive Services accounts | Foundry (Hub/Legacy) | N/A |

## Cost Analysis Approach

- **Billing periods over rolling dates:** The Runbook uses `Get-AzBillingPeriod` to align with how finance teams track spend, rather than arbitrary rolling date windows.
- **Service name filter:** Only costs attributed to `"Azure AI Foundry Models"` or `"Azure OpenAI Service"` are included.
- **Usage determination:** A deployment is considered **"In Use"** if its parent account has any non-zero cost across the queried billing periods. Per-period cost columns let admins see trends (increasing, decreasing, newly idle).
- **Graceful degradation:** If cost queries fail for a subscription or period, the Runbook logs a warning and continues. Deployments with unavailable cost data show zero costs.

## Report Format

### Columns

| Column | Description |
|---|---|
| SubscriptionName | Azure subscription display name |
| ResourceGroup | Resource group containing the Cognitive Services account |
| ResourceType | Classification: OpenAI Service, Foundry (Project), or Foundry (Hub/Legacy) |
| ResourceName | Cognitive Services account name |
| ProjectName | Foundry project name (blank for OpenAI and Hub/Legacy) |
| DeploymentName | Model deployment name |
| ModelName | Deployed model name (e.g., `gpt-4o`, `text-embedding-ada-002`) |
| ModelVersion | Model version string |
| SKU | Deployment SKU (e.g., Standard, GlobalStandard, ProvisionedManaged) |
| Capacity | Provisioned TPM/units |
| IsInUse | `True` if any non-zero cost exists across billing periods |
| Cost_{period} | Cost for each billing period (e.g., `Cost_202503`) |
| TotalCost | Sum of all period costs |

### Color Coding (HTML Report)

| Row Color | Meaning |
|---|---|
| 🟢 Green (`#dff6dd`) | Deployment is in use (has non-zero cost) |
| 🔴 Red (`#fde7e9`) | Deployment is unused (zero cost across all periods) |
