<#
.SYNOPSIS
    Model Hunter — discovers deployed Azure AI Foundry and OpenAI models across subscriptions,
    queries cost data, and uploads CSV + HTML reports to blob storage.

.DESCRIPTION
    Azure Automation Runbook (PowerShell 7.4) that:
    1. Authenticates via Managed Identity
    2. Discovers all CognitiveServices deployments using Azure Resource Graph
    3. Queries Cost Management for the last 3 billing periods
    4. Builds a merged CSV + HTML report with usage/cost data
    5. Uploads the reports to Azure Blob Storage

.PARAMETER SubscriptionIds
    Array of Azure subscription IDs to scan for model deployments.

.PARAMETER StorageAccountResourceId
    Full Azure resource ID of the storage account for report upload.
    Optional — when omitted, reports are saved locally to OutputPath.

.PARAMETER ContainerName
    Blob container name for report upload. Defaults to "model-discovery-reports".
    Only used when StorageAccountResourceId is provided.
#>

#region Parameters
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$SubscriptionIds,

    [string]$StorageAccountResourceId,

    [string]$ContainerName = "model-discovery-reports"
)

# OutputPath is only used for local runs (not exposed as a Runbook parameter)
$OutputPath = "./output"
#endregion Parameters

#region Module Check
# Verify required modules are available (gives clear error instead of silent failure)
$requiredModules = @('Az.Accounts', 'Az.ResourceGraph', 'Az.CostManagement', 'Az.Storage')
$missingModules = @()
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod -ErrorAction SilentlyContinue)) {
        $missingModules += $mod
    }
}
if ($missingModules.Count -gt 0) {
    throw "Missing required PowerShell modules: $($missingModules -join ', '). Install with: Install-Module $($missingModules -join ', ') -Force"
}
#endregion Module Check

#region Authentication
# Check if already authenticated (e.g., local dev via Connect-AzAccount)
# If not, attempt Managed Identity auth (Azure Automation)
# https://learn.microsoft.com/powershell/module/az.accounts/get-azcontext
$context = Get-AzContext -ErrorAction SilentlyContinue
if ($context) {
    Write-Output "========================================="
    Write-Output "STEP 1: Authentication"
    Write-Output "========================================="
    Write-Output "Using existing Azure context: $($context.Account.Id)"
    Write-Output "Tenant: $($context.Tenant.Id)"
    Write-Output "Subscription: $($context.Subscription.Name) ($($context.Subscription.Id))"
}
else {
    try {
        Write-Output "========================================="
        Write-Output "STEP 1: Authentication"
        Write-Output "========================================="
        Write-Output "No existing context found. Authenticating with Managed Identity..."
        # https://learn.microsoft.com/powershell/module/az.accounts/connect-azaccount
        Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
        Write-Output "Managed Identity authentication successful."
    }
    catch {
        throw "Not authenticated. Run 'Connect-AzAccount' locally or ensure Managed Identity is configured: $_"
    }
}
#endregion Authentication

#region Validation
Write-Output ""
Write-Output "========================================="
Write-Output "STEP 1b: Validating Access"
Write-Output "========================================="

# Validate each subscription is accessible
$validSubscriptionIds = [System.Collections.Generic.List[string]]::new()
foreach ($subId in $SubscriptionIds) {
    Write-Output "Checking subscription '$subId'..."
    try {
        # https://learn.microsoft.com/powershell/module/az.accounts/get-azsubscription
        $sub = Get-AzSubscription -SubscriptionId $subId -ErrorAction Stop
        Write-Output "  OK — $($sub.Name) ($($sub.State))"
        $validSubscriptionIds.Add($subId)
    }
    catch {
        Write-Warning "  SKIP — Cannot access subscription '$subId': $_"
    }
}

if ($validSubscriptionIds.Count -eq 0) {
    throw "No accessible subscriptions found. Verify the identity has Reader access to the target subscriptions."
}

if ($validSubscriptionIds.Count -lt $SubscriptionIds.Count) {
    Write-Warning "$($SubscriptionIds.Count - $validSubscriptionIds.Count) subscription(s) were inaccessible and will be skipped."
}
$SubscriptionIds = $validSubscriptionIds.ToArray()

# Validate storage account if provided
if ($StorageAccountResourceId) {
    Write-Output "Checking storage account..."
    if ($StorageAccountResourceId -notmatch '(?i)/providers/Microsoft\.Storage/storageAccounts/([^/]+)') {
        throw "Invalid StorageAccountResourceId format. Expected: /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Storage/storageAccounts/{name}"
    }
    $storageAccountName = $Matches[1]
    try {
        # https://learn.microsoft.com/powershell/module/az.storage/new-azstoragecontext
        $testContext = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount -ErrorAction Stop
        # Quick check: list containers to verify access (will fail fast if no permissions)
        Get-AzStorageContainer -Context $testContext -MaxCount 1 -ErrorAction Stop | Out-Null
        Write-Output "  OK — Storage account '$storageAccountName' is accessible."
    }
    catch {
        throw "Cannot access storage account '$storageAccountName'. Verify it exists and the identity has Storage Blob Data Contributor role: $_"
    }
}
else {
    Write-Output "No StorageAccountResourceId provided — reports will be saved locally to '$OutputPath'."
}
#endregion Validation

#region Functions: Get-ModelDeployments
function Get-ModelDeployments {
    <#
    .SYNOPSIS
        Discovers all CognitiveServices model deployments across the specified subscriptions.
    .DESCRIPTION
        Uses Azure Resource Graph to query accounts and deployments, then classifies each
        deployment as OpenAI Service, Foundry (Project), or Foundry (Hub/Legacy).
    .PARAMETER SubscriptionIds
        Array of subscription IDs to query.
    .OUTPUTS
        PSCustomObject[] — array of deployment objects with parsed fields.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$SubscriptionIds
    )

    Write-Host "Discovering model deployments across $($SubscriptionIds.Count) subscription(s)..."

    # Cache subscription names to avoid repeated lookups
    $subscriptionNameCache = @{}
    foreach ($subId in $SubscriptionIds) {
        if (-not $subscriptionNameCache.ContainsKey($subId)) {
            try {
                # https://learn.microsoft.com/powershell/module/az.accounts/get-azsubscription
                $sub = Get-AzSubscription -SubscriptionId $subId -ErrorAction Stop
                $subscriptionNameCache[$subId] = $sub.Name
            }
            catch {
                Write-Warning "Could not resolve subscription name for '$subId': $_"
                $subscriptionNameCache[$subId] = $subId
            }
        }
    }

    # Query 1: Get all CognitiveServices accounts (for kind classification)
    $accountQuery = @"
resources
| where type =~ 'microsoft.cognitiveservices/accounts'
| project id, name, resourceGroup, subscriptionId, kind, location
"@

    Write-Host "Querying CognitiveServices accounts via Resource Graph..."
    try {
        # https://learn.microsoft.com/powershell/module/az.resourcegraph/search-azgraph
        $accountResults = Search-AzGraph -Query $accountQuery -Subscription $SubscriptionIds -ErrorAction Stop
    }
    catch {
        throw "Failed to query CognitiveServices accounts: $_"
    }

    # Build a lookup of account ID (lowercase) → kind
    $accountKindMap = @{}
    foreach ($account in $accountResults) {
        $accountKindMap[$account.id.ToLower()] = $account.kind
    }

    # Filter to only accounts that could have AI model deployments
    $aiAccountResults = @($accountResults | Where-Object { $_.kind -in @('AIServices', 'OpenAI') })
    Write-Host "Found $($accountResults.Count) CognitiveServices account(s), $($aiAccountResults.Count) AI-capable (AIServices/OpenAI)."

    # Query projects to map account → project names
    # https://learn.microsoft.com/azure/templates/microsoft.cognitiveservices/accounts/projects
    $projectQuery = @"
resources
| where type =~ 'microsoft.cognitiveservices/accounts/projects'
| project id, name, subscriptionId
"@
    try {
        $projectResults = Search-AzGraph -Query $projectQuery -Subscription $SubscriptionIds -ErrorAction Stop
    }
    catch {
        Write-Warning "Could not query projects: $_"
        $projectResults = @()
    }

    # Build lookup: account ID (lowercase) → array of project names
    $accountProjectMap = @{}
    foreach ($proj in $projectResults) {
        if ($proj.id -match '(?i)(.*?/accounts/[^/]+)/projects/([^/]+)') {
            $parentAccountId = $Matches[1].ToLower()
            $projectName = $Matches[2]
            if (-not $accountProjectMap.ContainsKey($parentAccountId)) {
                $accountProjectMap[$parentAccountId] = @()
            }
            $accountProjectMap[$parentAccountId] += $projectName
        }
    }
    Write-Host "Found $($projectResults.Count) project(s) across $($accountProjectMap.Count) account(s)."

    # Query 2: For each account, list deployments via ARM API
    # Resource Graph may miss some deployment types (Global Standard, Data Zone, etc.)
    # The ARM API is authoritative for listing all deployments under an account.
    Write-Host "Querying deployments per account via ARM API..."
    $allDeploymentResults = [System.Collections.Generic.List[object]]::new()

    foreach ($account in $aiAccountResults) {
        $accountId = $account.id
        $acctName = $account.name
        $acctKind = $account.kind
        $acctRg = $account.resourceGroup
        $acctSubId = $account.subscriptionId

        Write-Verbose "  Listing deployments for $acctName ($acctKind)..."
        try {
            # https://learn.microsoft.com/rest/api/cognitiveservices/accountmanagement/deployments/list
            $deploymentsUrl = "https://management.azure.com${accountId}/deployments?api-version=2024-10-01"
            $response = Invoke-AzRestMethod -Uri $deploymentsUrl -Method GET -ErrorAction Stop

            if ($response.StatusCode -eq 200) {
                $deploymentsData = ($response.Content | ConvertFrom-Json).value
                if ($deploymentsData) {
                    # Query model lifecycle data for this account (once per account)
                    # https://learn.microsoft.com/rest/api/cognitiveservices/accountmanagement/models/list
                    $modelLifecycleMap = @{}
                    try {
                        $modelsUrl = "https://management.azure.com${accountId}/models?api-version=2024-10-01"
                        $modelsResp = Invoke-AzRestMethod -Uri $modelsUrl -Method GET -ErrorAction Stop
                        if ($modelsResp.StatusCode -eq 200) {
                            $modelsData = ($modelsResp.Content | ConvertFrom-Json).value
                            foreach ($mdl in $modelsData) {
                                $key = "$($mdl.name)|$($mdl.version)".ToLower()
                                $retireDate = $null
                                if ($mdl.deprecation -and $mdl.deprecation.inference) {
                                    $retireDate = $mdl.deprecation.inference
                                }
                                $modelLifecycleMap[$key] = [PSCustomObject]@{
                                    LifecycleStatus = $mdl.lifecycleStatus
                                    RetirementDate  = $retireDate
                                }
                            }
                        }
                    }
                    catch {
                        Write-Warning "    Could not query model lifecycle for '$acctName': $_"
                    }

                    foreach ($d in $deploymentsData) {
                        # Extract model info directly
                        $mName = $null; $mVersion = $null
                        if ($d.properties -and $d.properties.model) {
                            $mName    = $d.properties.model.name
                            $mVersion = $d.properties.model.version
                        }
                        # Extract SKU info directly
                        $sName = $null; $sCap = $null
                        if ($d.sku) {
                            $sName = $d.sku.name
                            $sCap  = $d.sku.capacity
                        }
                        # Check for project in deployment ID
                        $projName = $null
                        if ($d.id -match '(?i)/projects/([^/]+)') {
                            $projName = $Matches[1]
                        }

                        # Look up lifecycle info for this model+version
                        $lifecycleKey = "$($mName)|$($mVersion)".ToLower()
                        $lifecycle = $modelLifecycleMap[$lifecycleKey]
                        $lifecycleStatus = if ($lifecycle) { $lifecycle.LifecycleStatus } else { $null }
                        $retirementDate  = if ($lifecycle) { $lifecycle.RetirementDate } else { $null }

                        $allDeploymentResults.Add([PSCustomObject]@{
                            DeploymentId      = $d.id
                            DeploymentName    = $d.name
                            ModelName         = $mName
                            ModelVersion      = $mVersion
                            SKU               = $sName
                            Capacity          = $sCap
                            ProjectName       = $projName
                            AccountName       = $acctName
                            AccountKind       = $acctKind
                            AccountResourceId = $accountId.ToLower()
                            ResourceGroup     = $acctRg
                            SubscriptionId    = $acctSubId
                            LifecycleStatus   = $lifecycleStatus
                            RetirementDate    = $retirementDate
                        })
                    }
                    Write-Verbose "    Found $($deploymentsData.Count) deployment(s)."
                }
                else {
                    Write-Verbose "    No deployments."
                }
            }
            else {
                Write-Warning "    Failed to list deployments (HTTP $($response.StatusCode)): $($response.Content)"
            }
        }
        catch {
            Write-Warning "    Error listing deployments for '$acctName': $_"
        }
    }

    $deploymentResults = $allDeploymentResults.ToArray()
    Write-Host "Found $($deploymentResults.Count) total deployment(s) across all accounts."

    $deployments = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($dep in $deploymentResults) {
        # Look up projects for this account
        $acctIdLower = $dep.AccountResourceId
        $projects = if ($accountProjectMap.ContainsKey($acctIdLower)) { $accountProjectMap[$acctIdLower] } else { @() }
        $projectNameStr = if ($projects.Count -gt 0) { $projects -join '; ' } else { $null }

        # Classification:
        # - kind == "OpenAI" → "OpenAI Service"
        # - kind == "AIServices" → "Foundry"
        $resourceType = 'Foundry'
        if ($dep.AccountKind -eq 'OpenAI') {
            $resourceType = 'OpenAI Service'
        }

        $subscriptionName = $subscriptionNameCache[$dep.SubscriptionId]
        if (-not $subscriptionName) { $subscriptionName = $dep.SubscriptionId }

        $deployments.Add([PSCustomObject]@{
            SubscriptionId    = $dep.SubscriptionId
            SubscriptionName  = $subscriptionName
            ResourceGroupName = $dep.ResourceGroup
            ResourceType      = $resourceType
            ResourceName      = $dep.AccountName
            ProjectName       = $projectNameStr
            DeploymentName    = $dep.DeploymentName
            ModelName         = $dep.ModelName
            ModelVersion      = $dep.ModelVersion
            SKU               = $dep.SKU
            Capacity          = $dep.Capacity
            LifecycleStatus   = $dep.LifecycleStatus
            RetirementDate    = $dep.RetirementDate
            AccountResourceId = $dep.AccountResourceId
        })
    }

    Write-Host "Parsed $($deployments.Count) deployment(s) successfully."
    return $deployments.ToArray()
}
#endregion Functions: Get-ModelDeployments

#region Functions: Get-DeploymentCosts
function Get-DeploymentCosts {
    <#
    .SYNOPSIS
        Queries Azure Cost Management for AI-related costs across the last 3 billing periods.
    .DESCRIPTION
        Retrieves billing periods, then queries actual cost data. Filters results to only
        the specified account resource IDs. Returns a hashtable keyed by account resource ID
        with per-period costs.
    .PARAMETER SubscriptionIds
        Array of subscription IDs to query for cost data.
    .PARAMETER AccountResourceIds
        Array of CognitiveServices account resource IDs to match costs against.
    .OUTPUTS
        PSCustomObject with Costs (hashtable) and PeriodNames (string[]) properties.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$SubscriptionIds,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$AccountResourceIds
    )

    Write-Host "Querying cost data..."

    # Try billing periods first; fall back to last 3 calendar months if unavailable
    # (Get-AzBillingPeriod doesn't work for all account types: PAYG, MCA, etc.)
    $periods = @()
    $costMethod = $null
    try {
        # https://learn.microsoft.com/powershell/module/az.billing/get-azbillingperiod
        Write-Host "Attempting to retrieve Azure billing periods (preferred method)..."
        $billingPeriods = Get-AzBillingPeriod -MaxCount 3 -ErrorAction Stop
        if ($billingPeriods -and $billingPeriods.Count -gt 0) {
            $costMethod = "BillingPeriods"
            foreach ($bp in $billingPeriods) {
                $periods += [PSCustomObject]@{
                    Name      = $bp.Name
                    StartDate = $bp.BillingPeriodStartDate.ToString('yyyy-MM-dd')
                    EndDate   = $bp.BillingPeriodEndDate.ToString('yyyy-MM-dd')
                }
            }
            Write-Host "[Cost Method: Billing Periods] Retrieved $($periods.Count) period(s): $($periods.Name -join ', ')"
            foreach ($p in $periods) {
                Write-Host "  - $($p.Name): $($p.StartDate) to $($p.EndDate)"
            }
        }
        else {
            Write-Host "Get-AzBillingPeriod returned no results."
        }
    }
    catch {
        Write-Warning "Get-AzBillingPeriod failed: $_"
    }

    # Fallback: generate last 3 calendar months
    if ($periods.Count -eq 0) {
        $costMethod = "CalendarMonths"
        Write-Host "[Cost Method: Calendar Months] Billing periods unavailable — using last 3 calendar months as fallback."
        Write-Host "  This can happen with PAYG, MCA, or MSDN subscription types that don't expose billing periods via the API."
        $now = Get-Date
        for ($m = 0; $m -lt 3; $m++) {
            $monthStart = $now.AddMonths(-$m - 1)
            $firstDay = [datetime]::new($monthStart.Year, $monthStart.Month, 1)
            $lastDay = $firstDay.AddMonths(1).AddDays(-1)
            $periods += [PSCustomObject]@{
                Name      = $firstDay.ToString('yyyyMM')
                StartDate = $firstDay.ToString('yyyy-MM-dd')
                EndDate   = $lastDay.ToString('yyyy-MM-dd')
            }
        }
        # Sort oldest first
        $periods = $periods | Sort-Object Name
        foreach ($p in $periods) {
            Write-Host "  - $($p.Name): $($p.StartDate) to $($p.EndDate)"
        }
    }

    Write-Host "Cost query method: $costMethod | Periods: $($periods.Count)"

    $periodNames = @($periods | ForEach-Object { $_.Name })

    # Costs hashtable: key = lowercase account resource ID, value = hashtable of period → cost
    $costs = @{}
    $currency = 'USD'  # Default; updated from first cost result with a currency column

    foreach ($subId in $SubscriptionIds) {
        # Get the account resource IDs for this subscription from the passed-in list
        $subAccountIds = @($AccountResourceIds | Where-Object { $_ -match "(?i)/subscriptions/$subId/" })
        if ($subAccountIds.Count -eq 0) {
            Write-Host "No CognitiveServices accounts in subscription '$subId' — skipping cost query."
            continue
        }

        foreach ($period in $periods) {
            $periodName = $period.Name
            $startDate  = $period.StartDate
            $endDate    = $period.EndDate

            Write-Host "Querying costs for subscription '$subId', period '$periodName' ($startDate to $endDate)..."

            $scope = "/subscriptions/$subId"

            try {
                # Query all costs grouped by ResourceId — we'll filter to our accounts in code
                # This avoids filter mismatches with the Cost Management API
                # https://learn.microsoft.com/powershell/module/az.costmanagement/invoke-azcostmanagementquery
                $costResult = Invoke-AzCostManagementQuery `
                    -Scope $scope `
                    -Type 'ActualCost' `
                    -Timeframe 'Custom' `
                    -TimePeriodFrom $startDate `
                    -TimePeriodTo $endDate `
                    -DatasetGranularity 'None' `
                    -DatasetAggregation @{
                        totalCost = @{ name = 'Cost'; function = 'Sum' }
                    } `
                    -DatasetGrouping @(
                        @{ type = 'Dimension'; name = 'ResourceId' },
                        @{ type = 'Dimension'; name = 'MeterCategory' }
                    ) `
                    -ErrorAction Stop
            }
            catch {
                Write-Warning "Cost query failed for subscription '$subId', period '$periodName': $_"
                continue
            }

            if (-not $costResult -or -not $costResult.Row) {
                Write-Verbose "  No cost rows returned."
                continue
            }

            # Parse cost result columns — names vary by API version and query type
            $columns = $costResult.Column
            $costIndex        = -1
            $resourceIdIndex  = -1
            $serviceNameIndex = -1
            $currencyIndex    = -1

            for ($i = 0; $i -lt $columns.Count; $i++) {
                $colName = $columns[$i].Name.ToLower()
                $colType = $columns[$i].Type.ToLower()

                if ($colType -eq 'number' -and $costIndex -lt 0) { $costIndex = $i }
                if ($colName -match 'cost|pretaxcost|totalcost') { $costIndex = $i }
                if ($colName -match 'resourceid') { $resourceIdIndex = $i }
                if ($colName -match 'currency') { $currencyIndex = $i }
                if ($colName -match 'metercategory|servicename') { $serviceNameIndex = $i }
            }

            if ($costIndex -lt 0 -or $resourceIdIndex -lt 0) {
                Write-Warning "Could not parse cost columns for '$periodName'. Columns: $(($columns | ForEach-Object { $_.Name }) -join ', ')"
                continue
            }

            $periodRowCount = 0
            foreach ($row in $costResult.Row) {
                $costAmount = [decimal]$row[$costIndex]
                $rawResourceId = [string]$row[$resourceIdIndex]
                $serviceName = if ($serviceNameIndex -ge 0) { [string]$row[$serviceNameIndex] } else { 'N/A' }

                # Capture currency from the first row that has one
                if ($currencyIndex -ge 0 -and $currency -eq 'USD') {
                    $rowCurrency = [string]$row[$currencyIndex]
                    if ($rowCurrency) { $currency = $rowCurrency }
                }

                # Normalize the resource ID to account level (strip /deployments/... and /projects/...)
                $accountId = $rawResourceId
                if ($accountId -match '(?i)/providers/Microsoft\.CognitiveServices/accounts/[^/]+') {
                    $accountId = $Matches[0]
                    # Prepend the subscription/RG portion
                    $prefixMatch = $rawResourceId -match '(?i)^(/subscriptions/[^/]+/resourceGroups/[^/]+)'
                    if ($prefixMatch) {
                        $accountId = $Matches[1] + $accountId
                    }
                }
                $accountIdLower = $accountId.ToLower()

                # Only include costs for accounts we discovered (skip Speech, Vision, etc.)
                $isKnownAccount = $false
                foreach ($known in $subAccountIds) {
                    if ($known.ToLower() -eq $accountIdLower) {
                        $isKnownAccount = $true
                        break
                    }
                }
                if (-not $isKnownAccount) { continue }

                if ($costAmount -gt 0) {
                    $periodRowCount++
                }

                if (-not $costs.ContainsKey($accountIdLower)) {
                    $costs[$accountIdLower] = @{}
                }
                if (-not $costs[$accountIdLower].ContainsKey($periodName)) {
                    $costs[$accountIdLower][$periodName] = [decimal]0
                }
                $costs[$accountIdLower][$periodName] += $costAmount
            }
        }
    }

    Write-Host "Cost query complete. Found cost data for $($costs.Count) account(s). Currency: $currency"

    return [PSCustomObject]@{
        Costs       = $costs
        PeriodNames = $periodNames
        Currency    = $currency
    }
}
#endregion Functions: Get-DeploymentCosts

#region Functions: Build-Report
function Build-Report {
    <#
    .SYNOPSIS
        Merges deployment data with cost data and generates CSV + HTML report content.
    .DESCRIPTION
        Joins deployments with cost data by AccountResourceId. Produces a styled HTML table
        with green (in use) / red-orange (unused) row highlighting and a CSV export.
    .PARAMETER Deployments
        Array of deployment objects from Get-ModelDeployments.
    .PARAMETER Costs
        Hashtable of costs keyed by lowercase account resource ID.
    .PARAMETER BillingPeriodNames
        Array of billing period names for column headers.
    .OUTPUTS
        PSCustomObject with CsvContent and HtmlContent properties.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [PSCustomObject[]]$Deployments,

        [Parameter(Mandatory)]
        [AllowNull()]
        [hashtable]$Costs,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$BillingPeriodNames,

        [string]$Currency = 'USD'
    )

    Write-Host "Building report for $($Deployments.Count) deployment(s)..."

    if (-not $Costs) { $Costs = @{} }
    if (-not $BillingPeriodNames) { $BillingPeriodNames = @() }

    $reportRows = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($dep in $Deployments) {
        $accountKey = if ($dep.AccountResourceId) { $dep.AccountResourceId } else { '' }
        $accountCosts = if ($accountKey -and $Costs.ContainsKey($accountKey)) { $Costs[$accountKey] } else { $null }

        $totalCost = [decimal]0
        $periodCosts = @{}

        foreach ($periodName in $BillingPeriodNames) {
            $periodCost = [decimal]0
            if ($accountCosts -and $accountCosts.ContainsKey($periodName)) {
                $periodCost = $accountCosts[$periodName]
            }
            $periodCosts[$periodName] = $periodCost
            $totalCost += $periodCost
        }

        $isInUse = $totalCost -gt 0

        # Format retirement date as YYYY-MM
        $retireDateStr = $null
        if ($dep.RetirementDate) {
            try { $retireDateStr = ([datetime]$dep.RetirementDate).ToString('yyyy-MM') } catch { $retireDateStr = [string]$dep.RetirementDate }
        }

        $row = [PSCustomObject]@{
            SubscriptionName = $dep.SubscriptionName
            ResourceGroup    = $dep.ResourceGroupName
            ResourceType     = $dep.ResourceType
            ResourceName     = $dep.ResourceName
            ProjectName      = $dep.ProjectName
            DeploymentName   = $dep.DeploymentName
            ModelName        = $dep.ModelName
            ModelVersion     = $dep.ModelVersion
            LifecycleStatus  = $dep.LifecycleStatus
            RetirementDate   = $retireDateStr
            SKU              = $dep.SKU
            Capacity         = $dep.Capacity
            IsInUse          = $isInUse
        }

        # Add dynamic cost columns per billing period
        foreach ($periodName in $BillingPeriodNames) {
            $row | Add-Member -NotePropertyName "Cost_$periodName" -NotePropertyValue $periodCosts[$periodName]
        }
        $row | Add-Member -NotePropertyName 'TotalCost' -NotePropertyValue $totalCost

        $reportRows.Add($row)
    }

    # Compute summary statistics
    $totalDeployments = $reportRows.Count
    $deploymentsWithCost = @($reportRows | Where-Object { $_.IsInUse -eq $true }).Count
    $deploymentsNoCost = $totalDeployments - $deploymentsWithCost
    $uniqueModels = @($reportRows | ForEach-Object { $_.ModelName } | Where-Object { $_ } | Select-Object -Unique)
    $modelsWithCost = @($reportRows | Where-Object { $_.IsInUse -eq $true } | ForEach-Object { $_.ModelName } | Where-Object { $_ } | Select-Object -Unique)
    $uniqueAccounts = @($reportRows | ForEach-Object { $_.ResourceName } | Where-Object { $_ } | Select-Object -Unique)
    $uniqueSubs = @($reportRows | ForEach-Object { $_.SubscriptionName } | Where-Object { $_ } | Select-Object -Unique)
    $totalCostSum = ($reportRows | ForEach-Object { if ($_.TotalCost) { [decimal]$_.TotalCost } else { 0 } } | Measure-Object -Sum).Sum
    $retiringCount = @($reportRows | Where-Object { $_.RetirementDate } ).Count
    $retiringSoonCount = @($reportRows | Where-Object {
        if ($_.RetirementDate) {
            try { ([datetime]::ParseExact($_.RetirementDate, 'yyyy-MM', $null)).AddMonths(1).AddDays(-1) -le (Get-Date).AddDays(90) } catch { $false }
        } else { $false }
    }).Count

    # Generate summary CSV content
    $summaryRows = [System.Collections.Generic.List[PSCustomObject]]::new()
    $summaryRows.Add([PSCustomObject]@{ Metric = 'Report Generated'; Value = $timestamp })
    $summaryRows.Add([PSCustomObject]@{ Metric = 'Subscriptions Scanned'; Value = $uniqueSubs.Count })
    $summaryRows.Add([PSCustomObject]@{ Metric = 'AI Accounts Found'; Value = $uniqueAccounts.Count })
    $summaryRows.Add([PSCustomObject]@{ Metric = 'Total Deployments'; Value = $totalDeployments })
    $summaryRows.Add([PSCustomObject]@{ Metric = 'Deployments With Cost'; Value = $deploymentsWithCost })
    $summaryRows.Add([PSCustomObject]@{ Metric = 'Deployments Without Cost'; Value = $deploymentsNoCost })
    $summaryRows.Add([PSCustomObject]@{ Metric = 'Unique Models Deployed'; Value = $uniqueModels.Count })
    $summaryRows.Add([PSCustomObject]@{ Metric = 'Unique Models With Cost'; Value = $modelsWithCost.Count })
    $summaryRows.Add([PSCustomObject]@{ Metric = 'Models With Retirement Date'; Value = $retiringCount })
    $summaryRows.Add([PSCustomObject]@{ Metric = 'Total Cost (All Periods)'; Value = "$Currency $('{0:N2}' -f $totalCostSum)" })
    $summaryRows.Add([PSCustomObject]@{ Metric = 'Currency'; Value = $Currency })
    $summaryRows.Add([PSCustomObject]@{ Metric = 'Billing Periods'; Value = ($BillingPeriodNames -join ', ') })
    $summaryCsvContent = ($summaryRows | ConvertTo-Csv -NoTypeInformation) -join "`n"

    # Generate detail CSV content
    $csvContent = ''
    if ($reportRows.Count -gt 0) {
        $csvContent = ($reportRows | ConvertTo-Csv -NoTypeInformation) -join "`n"
    }

    # Generate HTML content with summary dashboard
    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss UTC')
    $htmlBuilder = [System.Text.StringBuilder]::new()
    [void]$htmlBuilder.AppendLine('<!DOCTYPE html>')
    [void]$htmlBuilder.AppendLine('<html lang="en">')
    [void]$htmlBuilder.AppendLine('<head>')
    [void]$htmlBuilder.AppendLine('  <meta charset="UTF-8">')
    [void]$htmlBuilder.AppendLine("  <title>Model Hunter Report — $timestamp</title>")
    [void]$htmlBuilder.AppendLine('  <style>')
    [void]$htmlBuilder.AppendLine('    * { box-sizing: border-box; }')
    [void]$htmlBuilder.AppendLine('    body { font-family: Segoe UI, Arial, sans-serif; margin: 0; padding: 20px 30px; background: #f4f6f8; color: #333; }')
    [void]$htmlBuilder.AppendLine('    h1 { color: #1a1a2e; margin-bottom: 4px; }')
    [void]$htmlBuilder.AppendLine('    .subtitle { color: #666; margin-bottom: 24px; font-size: 14px; }')
    [void]$htmlBuilder.AppendLine('    .dashboard { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 16px; margin-bottom: 28px; }')
    [void]$htmlBuilder.AppendLine('    .card { background: #fff; border-radius: 8px; padding: 16px 20px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }')
    [void]$htmlBuilder.AppendLine('    .card .label { font-size: 12px; color: #888; text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 4px; }')
    [void]$htmlBuilder.AppendLine('    .card .value { font-size: 28px; font-weight: 600; color: #1a1a2e; }')
    [void]$htmlBuilder.AppendLine('    .card .value.green { color: #2e7d32; }')
    [void]$htmlBuilder.AppendLine('    .card .value.red { color: #c62828; }')
    [void]$htmlBuilder.AppendLine('    .card .value.blue { color: #0078d4; }')
    [void]$htmlBuilder.AppendLine('    .card .detail { font-size: 11px; color: #999; margin-top: 4px; }')
    [void]$htmlBuilder.AppendLine('    h2 { color: #1a1a2e; margin-top: 0; }')
    [void]$htmlBuilder.AppendLine('    .table-container { background: #fff; border-radius: 8px; padding: 16px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); overflow-x: auto; }')
    [void]$htmlBuilder.AppendLine('    table { border-collapse: collapse; width: 100%; font-size: 12px; }')
    [void]$htmlBuilder.AppendLine('    th { background: #1a1a2e; color: #fff; padding: 10px 12px; text-align: left; font-weight: 500; white-space: nowrap; position: sticky; top: 0; }')
    [void]$htmlBuilder.AppendLine('    td { padding: 8px 12px; border-bottom: 1px solid #eee; white-space: nowrap; }')
    [void]$htmlBuilder.AppendLine('    tr.in-use { background: #f1f8e9; }')
    [void]$htmlBuilder.AppendLine('    tr.unused { background: #fff3e0; }')
    [void]$htmlBuilder.AppendLine('    tr:hover td { background: rgba(0,120,212,0.06); }')
    [void]$htmlBuilder.AppendLine('    .badge { display: inline-block; padding: 2px 8px; border-radius: 10px; font-size: 11px; font-weight: 500; }')
    [void]$htmlBuilder.AppendLine('    .badge-yes { background: #e8f5e9; color: #2e7d32; }')
    [void]$htmlBuilder.AppendLine('    .badge-no { background: #fbe9e7; color: #c62828; }')
    [void]$htmlBuilder.AppendLine('    .cost { text-align: right; font-variant-numeric: tabular-nums; }')
    [void]$htmlBuilder.AppendLine('  </style>')
    [void]$htmlBuilder.AppendLine('</head>')
    [void]$htmlBuilder.AppendLine('<body>')
    [void]$htmlBuilder.AppendLine("  <h1>Model Hunter Report</h1>")
    [void]$htmlBuilder.AppendLine("  <p class=`"subtitle`">Generated: $timestamp</p>")

    # Summary dashboard cards
    [void]$htmlBuilder.AppendLine('  <div class="dashboard">')
    [void]$htmlBuilder.AppendLine("    <div class=`"card`"><div class=`"label`">Total Deployments</div><div class=`"value blue`">$totalDeployments</div></div>")
    [void]$htmlBuilder.AppendLine("    <div class=`"card`"><div class=`"label`">Deployments With Cost</div><div class=`"value green`">$deploymentsWithCost</div></div>")
    [void]$htmlBuilder.AppendLine("    <div class=`"card`"><div class=`"label`">Deployments No Cost</div><div class=`"value red`">$deploymentsNoCost</div></div>")
    [void]$htmlBuilder.AppendLine("    <div class=`"card`"><div class=`"label`">Unique Models</div><div class=`"value blue`">$($uniqueModels.Count)</div><div class=`"detail`">$($modelsWithCost.Count) with cost</div></div>")
    [void]$htmlBuilder.AppendLine("    <div class=`"card`"><div class=`"label`">AI Accounts</div><div class=`"value`">$($uniqueAccounts.Count)</div></div>")
    [void]$htmlBuilder.AppendLine("    <div class=`"card`"><div class=`"label`">Retiring in 90 Days</div><div class=`"value$(if ($retiringSoonCount -gt 0) { ' red' })`">$retiringSoonCount</div><div class=`"detail`">$retiringCount total with retirement date</div></div>")
    [void]$htmlBuilder.AppendLine("    <div class=`"card`"><div class=`"label`">Total Cost ($Currency)</div><div class=`"value green`">$('{0:N2}' -f $totalCostSum)</div><div class=`"detail`">across $($BillingPeriodNames.Count) period(s)</div></div>")
    [void]$htmlBuilder.AppendLine('  </div>')

    # Deployment table
    [void]$htmlBuilder.AppendLine('  <div class="table-container">')
    [void]$htmlBuilder.AppendLine('  <h2>Deployment Details</h2>')
    [void]$htmlBuilder.AppendLine('  <table>')

    # Header row — use friendly names
    [void]$htmlBuilder.AppendLine('    <thead><tr>')
    $headerColumns = @(
        'SubscriptionName', 'ResourceGroup', 'ResourceType', 'ResourceName',
        'ProjectName', 'DeploymentName', 'ModelName', 'ModelVersion',
        'LifecycleStatus', 'RetirementDate', 'SKU', 'Capacity', 'IsInUse'
    )
    foreach ($periodName in $BillingPeriodNames) {
        $headerColumns += "Cost_$periodName"
    }
    $headerColumns += 'TotalCost'

    $friendlyNames = @{
        'SubscriptionName' = 'Subscription'
        'ResourceGroup'    = 'Resource Group'
        'ResourceType'     = 'Type'
        'ResourceName'     = 'Resource'
        'ProjectName'      = 'Project'
        'DeploymentName'   = 'Deployment'
        'ModelName'        = 'Model'
        'ModelVersion'     = 'Version'
        'LifecycleStatus' = 'Status'
        'RetirementDate'  = 'Retirement'
        'SKU'              = 'SKU'
        'Capacity'         = 'Capacity'
        'IsInUse'          = 'In Use'
        'TotalCost'        = 'Total Cost'
    }

    foreach ($col in $headerColumns) {
        $displayName = if ($friendlyNames.ContainsKey($col)) { $friendlyNames[$col] }
                       elseif ($col -match '^Cost_(.+)$') { $Matches[1] }
                       else { $col }
        $align = if ($col -like 'Cost_*' -or $col -eq 'TotalCost') { ' class="cost"' } else { '' }
        [void]$htmlBuilder.AppendLine("      <th$align>$displayName</th>")
    }
    [void]$htmlBuilder.AppendLine('    </tr></thead>')

    # Data rows
    [void]$htmlBuilder.AppendLine('    <tbody>')
    foreach ($row in $reportRows) {
        $rowClass = if ($row.IsInUse) { 'in-use' } else { 'unused' }
        [void]$htmlBuilder.AppendLine("    <tr class=`"$rowClass`">")
        foreach ($col in $headerColumns) {
            $value = $row.$col
            if ($null -eq $value) { $value = '' }

            if ($col -eq 'IsInUse') {
                $badgeClass = if ($value) { 'badge-yes' } else { 'badge-no' }
                $badgeText = if ($value) { 'Yes' } else { 'No' }
                $value = "<span class=`"badge $badgeClass`">$badgeText</span>"
                [void]$htmlBuilder.AppendLine("      <td>$value</td>")
            }
            elseif ($col -like 'Cost_*' -or $col -eq 'TotalCost') {
                $value = '${0:N2}' -f [decimal]$value
                [void]$htmlBuilder.AppendLine("      <td class=`"cost`">$value</td>")
            }
            else {
                $value = [string]$value -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
                [void]$htmlBuilder.AppendLine("      <td>$value</td>")
            }
        }
        [void]$htmlBuilder.AppendLine('    </tr>')
    }
    [void]$htmlBuilder.AppendLine('    </tbody>')
    [void]$htmlBuilder.AppendLine('  </table>')
    [void]$htmlBuilder.AppendLine('  </div>')
    [void]$htmlBuilder.AppendLine('</body>')
    [void]$htmlBuilder.AppendLine('</html>')

    $htmlContent = $htmlBuilder.ToString()

    Write-Host "Report built: $($reportRows.Count) row(s)."

    return [PSCustomObject]@{
        CsvContent     = $csvContent
        SummaryCsv     = $summaryCsvContent
        HtmlContent    = $htmlContent
    }
}
#endregion Functions: Build-Report

#region Functions: Publish-Report
function Publish-Report {
    <#
    .SYNOPSIS
        Uploads CSV and HTML report content to Azure Blob Storage.
    .DESCRIPTION
        Parses the storage account from its resource ID, creates a storage context using
        Managed Identity, and uploads both files with timestamped names.
    .PARAMETER CsvContent
        CSV report string to upload.
    .PARAMETER HtmlContent
        HTML report string to upload.
    .PARAMETER StorageAccountResourceId
        Full Azure resource ID of the target storage account.
    .PARAMETER ContainerName
        Blob container name for the upload.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CsvContent,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$HtmlContent,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$StorageAccountResourceId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ContainerName
    )

    Write-Host "Publishing reports to blob storage..."

    # Parse storage account name from resource ID
    # Pattern: /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Storage/storageAccounts/{name}
    if ($StorageAccountResourceId -notmatch '(?i)/providers/Microsoft\.Storage/storageAccounts/([^/]+)') {
        throw "Could not parse storage account name from resource ID: $StorageAccountResourceId"
    }
    $storageAccountName = $Matches[1]
    Write-Verbose "Storage account: $storageAccountName"

    # Create storage context using connected account (Managed Identity)
    try {
        # https://learn.microsoft.com/powershell/module/az.storage/new-azstoragecontext
        $storageContext = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount -ErrorAction Stop
    }
    catch {
        throw "Failed to create storage context for '$storageAccountName': $_"
    }

    $timestamp = (Get-Date).ToString('yyyy-MM-dd-HHmmss')
    $csvBlobName  = "model-discovery-$timestamp.csv"
    $htmlBlobName = "model-discovery-$timestamp.html"

    # Write content to temporary files for upload
    $tempCsvPath  = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), $csvBlobName)
    $tempHtmlPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), $htmlBlobName)

    try {
        [System.IO.File]::WriteAllText($tempCsvPath, $CsvContent)
        [System.IO.File]::WriteAllText($tempHtmlPath, $HtmlContent)

        # https://learn.microsoft.com/powershell/module/az.storage/set-azstorageblobcontent
        Set-AzStorageBlobContent `
            -File $tempCsvPath `
            -Container $ContainerName `
            -Blob $csvBlobName `
            -Context $storageContext `
            -Properties @{ ContentType = 'text/csv' } `
            -Force `
            -ErrorAction Stop | Out-Null

        Write-Host "Uploaded CSV: $csvBlobName"

        # https://learn.microsoft.com/powershell/module/az.storage/set-azstorageblobcontent
        Set-AzStorageBlobContent `
            -File $tempHtmlPath `
            -Container $ContainerName `
            -Blob $htmlBlobName `
            -Context $storageContext `
            -Properties @{ ContentType = 'text/html' } `
            -Force `
            -ErrorAction Stop | Out-Null

        Write-Host "Uploaded HTML: $htmlBlobName"
    }
    catch {
        throw "Failed to upload report to blob storage: $_"
    }
    finally {
        # Clean up temporary files
        if (Test-Path $tempCsvPath)  { Remove-Item $tempCsvPath  -Force -ErrorAction SilentlyContinue }
        if (Test-Path $tempHtmlPath) { Remove-Item $tempHtmlPath -Force -ErrorAction SilentlyContinue }
    }

    Write-Host "Reports published to container '$ContainerName' in storage account '$storageAccountName'."
}
#endregion Functions: Publish-Report

#region Main Execution
$startTime = Get-Date

Write-Output ""
Write-Output "########################################"
Write-Output "  Model Hunter — Starting"
Write-Output "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')"
Write-Output "########################################"
Write-Output ""

Write-Output "========================================="
Write-Output "STEP 2: Discovering Model Deployments"
Write-Output "========================================="
Write-Output "Scanning $($SubscriptionIds.Count) subscription(s): $($SubscriptionIds -join ', ')"
$deployments = Get-ModelDeployments -SubscriptionIds $SubscriptionIds

# Show a preview of discovered deployments
if ($deployments.Count -gt 0) {
    Write-Output ""
    Write-Output "Discovered deployments:"
    foreach ($d in $deployments) {
        Write-Output "  [$($d.ResourceType)] $($d.ResourceName)/$($d.DeploymentName) — Model: $($d.ModelName) $($d.ModelVersion) | SKU: $($d.SKU) | Sub: $($d.SubscriptionName)"
    }
}
else {
    Write-Warning "No deployments found across the scanned subscriptions."
}

Write-Output ""
Write-Output "========================================="
Write-Output "STEP 3: Querying Cost Data"
Write-Output "========================================="
# Extract unique account resource IDs from discovered deployments for cost matching
$accountResourceIds = @($deployments | ForEach-Object { $_.AccountResourceId } | Where-Object { $_ } | Select-Object -Unique)
Write-Output "Querying costs for $($accountResourceIds.Count) unique account(s)..."
$costResult = Get-DeploymentCosts -SubscriptionIds $SubscriptionIds -AccountResourceIds $accountResourceIds

$billingPeriodNames = if ($costResult.PeriodNames) { $costResult.PeriodNames } else { @() }
$costs = if ($costResult.Costs) { $costResult.Costs } else { @{} }
$currency = if ($costResult.Currency) { $costResult.Currency } else { 'USD' }

Write-Output ""
Write-Output "========================================="
Write-Output "STEP 4: Merging Data & Building Report"
Write-Output "========================================="
Write-Output "Merging $($deployments.Count) deployment(s) with cost data from $($billingPeriodNames.Count) period(s) (currency: $currency)..."
$report = Build-Report `
    -Deployments $deployments `
    -Costs $costs `
    -BillingPeriodNames $billingPeriodNames `
    -Currency $currency

Write-Output ""
Write-Output "========================================="
Write-Output "STEP 5: Publishing Report"
Write-Output "========================================="

if ($report.CsvContent -and $report.HtmlContent) {
    if ($StorageAccountResourceId) {
        Write-Output "Uploading to Azure Blob Storage..."
        Publish-Report `
            -CsvContent $report.CsvContent `
            -HtmlContent $report.HtmlContent `
            -StorageAccountResourceId $StorageAccountResourceId `
            -ContainerName $ContainerName
    }
    else {
        # Local output mode — clear previous results
        if (Test-Path $OutputPath) {
            Remove-Item "$OutputPath/*" -Force -ErrorAction SilentlyContinue
        }
        else {
            New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
        }
        $timestamp = (Get-Date).ToString('yyyy-MM-dd-HHmmss')
        $csvFile     = Join-Path $OutputPath "model-discovery-$timestamp.csv"
        $summaryFile = Join-Path $OutputPath "model-discovery-summary-$timestamp.csv"
        $htmlFile    = Join-Path $OutputPath "model-discovery-$timestamp.html"

        [System.IO.File]::WriteAllText($csvFile, $report.CsvContent)
        [System.IO.File]::WriteAllText($summaryFile, $report.SummaryCsv)
        [System.IO.File]::WriteAllText($htmlFile, $report.HtmlContent)

        Write-Output "Reports saved locally:"
        Write-Output "  Detail CSV:  $csvFile"
        Write-Output "  Summary CSV: $summaryFile"
        Write-Output "  HTML:        $htmlFile"
    }
}
else {
    Write-Warning "Report content is empty — skipping output. Check for errors above."
}

$endTime = Get-Date
$duration = $endTime - $startTime

# Compute summary stats
$uniqueModels = @($deployments | ForEach-Object { $_.ModelName } | Where-Object { $_ } | Select-Object -Unique)
$uniqueSubs = @($deployments | ForEach-Object { $_.SubscriptionName } | Where-Object { $_ } | Select-Object -Unique)
$inUseCount = 0
$unusedCount = 0
if ($report -and $report.CsvContent) {
    # Count from the merged data
    $inUseCount = @($deployments | Where-Object {
        $key = if ($_.AccountResourceId) { $_.AccountResourceId } else { '' }
        $key -and $costs.ContainsKey($key) -and ($costs[$key].Values | Measure-Object -Sum).Sum -gt 0
    }).Count
    $unusedCount = $deployments.Count - $inUseCount
}

Write-Output ""
Write-Output "########################################"
Write-Output "  Model Hunter — Summary"
Write-Output "########################################"
Write-Output "  Duration:              $($duration.ToString('hh\:mm\:ss'))"
Write-Output "  Subscriptions scanned: $($uniqueSubs.Count) ($($uniqueSubs -join ', '))"
Write-Output "  Total deployments:     $($deployments.Count)"
Write-Output "  Unique models:         $($uniqueModels.Count) ($($uniqueModels -join ', '))"
Write-Output "  In use (with cost):    $inUseCount"
Write-Output "  Unused (zero cost):    $unusedCount"
Write-Output "  Cost periods queried:  $($billingPeriodNames.Count)"
Write-Output "  Output mode:           $(if ($StorageAccountResourceId) { 'Azure Blob Storage' } else { "Local ($OutputPath)" })"
Write-Output "########################################"
#endregion Main Execution
