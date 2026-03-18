#requires -Modules Az.Accounts, Az.ResourceGraph, Az.Billing, Az.CostManagement, Az.Storage

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

.PARAMETER OutputPath
    Local directory for report output when StorageAccountResourceId is not provided.
    Defaults to "./output".
#>

#region Parameters
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$SubscriptionIds,

    [string]$StorageAccountResourceId,

    [string]$ContainerName = "model-discovery-reports",

    [string]$OutputPath = "./output"
)
#endregion Parameters

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

    Write-Output "Discovering model deployments across $($SubscriptionIds.Count) subscription(s)..."

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

    Write-Output "Querying CognitiveServices accounts via Resource Graph..."
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
    Write-Output "Found $($accountResults.Count) CognitiveServices account(s)."

    # Query 2: For each account, list deployments via ARM API
    # Resource Graph may miss some deployment types (Global Standard, Data Zone, etc.)
    # The ARM API is authoritative for listing all deployments under an account.
    Write-Output "Querying deployments per account via ARM API..."
    $allDeploymentResults = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($account in $accountResults) {
        $accountId = $account.id
        $acctName = $account.name
        $acctKind = $account.kind
        $acctRg = $account.resourceGroup
        $acctSubId = $account.subscriptionId

        Write-Output "  Listing deployments for $acctName ($acctKind)..."
        try {
            # https://learn.microsoft.com/rest/api/cognitiveservices/accountmanagement/deployments/list
            $deploymentsUrl = "https://management.azure.com${accountId}/deployments?api-version=2024-10-01"
            $response = Invoke-AzRestMethod -Uri $deploymentsUrl -Method GET -ErrorAction Stop

            if ($response.StatusCode -eq 200) {
                $deploymentsData = ($response.Content | ConvertFrom-Json).value
                if ($deploymentsData) {
                    foreach ($d in $deploymentsData) {
                        $allDeploymentResults.Add([PSCustomObject]@{
                            id                = $d.id
                            name              = $d.name
                            properties        = $d.properties
                            sku               = $d.sku
                            _accountName      = $acctName
                            _accountKind      = $acctKind
                            _accountId        = $accountId
                            _resourceGroup    = $acctRg
                            _subscriptionId   = $acctSubId
                        })
                    }
                    Write-Output "    Found $($deploymentsData.Count) deployment(s)."
                }
                else {
                    Write-Output "    No deployments."
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
    Write-Output "Found $($deploymentResults.Count) total deployment(s) across all accounts."

    $deployments = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($dep in $deploymentResults) {
        # Use pre-populated account context from the ARM query
        $subId          = $dep._subscriptionId
        $rgName         = $dep._resourceGroup
        $accountName    = $dep._accountName
        $accountKind    = $dep._accountKind
        $accountResId   = $dep._accountId
        $deploymentName = $dep.name

        # Check for project in the deployment resource ID
        $projectName = $null
        $resourceId = $dep.id
        if ($resourceId -match '(?i)/projects/([^/]+)') {
            $projectName = $Matches[1]
        }

        # Classification rules (in order):
        # 1. kind == "OpenAI" → "OpenAI Service"
        # 2. Resource ID contains /projects/ → "Foundry (Project)"
        # 3. Otherwise → "Foundry (Hub/Legacy)"
        if ($accountKind -eq 'OpenAI') {
            $resourceType = 'OpenAI Service'
        }
        elseif ($projectName) {
            $resourceType = 'Foundry (Project)'
        }
        else {
            $resourceType = 'Foundry (Hub/Legacy)'
        }

        # Extract model info from properties (ARM API returns PSObject from ConvertFrom-Json)
        $modelName    = $null
        $modelVersion = $null
        $props = $dep.properties
        if ($props) {
            $model = $props.model
            if ($model) {
                $modelName    = $model.name
                $modelVersion = $model.version
            }
        }

        # Extract SKU info
        $skuName  = $null
        $capacity = $null
        $skuObj = $dep.sku
        if ($skuObj) {
            $skuName  = $skuObj.name
            $capacity = $skuObj.capacity
        }

        $subscriptionName = $subscriptionNameCache[$subId]
        if (-not $subscriptionName) { $subscriptionName = $subId }

        $deployments.Add([PSCustomObject]@{
            SubscriptionId    = $subId
            SubscriptionName  = $subscriptionName
            ResourceGroupName = $rgName
            ResourceType      = $resourceType
            ResourceName      = $accountName
            ProjectName       = $projectName
            DeploymentName    = $deploymentName
            ModelName         = $modelName
            ModelVersion      = $modelVersion
            SKU               = $skuName
            Capacity          = $capacity
            AccountResourceId = $accountResId.ToLower()
        })
    }

    Write-Output "Parsed $($deployments.Count) deployment(s) successfully."
    return $deployments.ToArray()
}
#endregion Functions: Get-ModelDeployments

#region Functions: Get-DeploymentCosts
function Get-DeploymentCosts {
    <#
    .SYNOPSIS
        Queries Azure Cost Management for AI-related costs across the last 3 billing periods.
    .DESCRIPTION
        Retrieves billing periods, then queries actual cost data filtered to Foundry/OpenAI
        services. Returns a hashtable keyed by account resource ID with per-period costs.
    .PARAMETER SubscriptionIds
        Array of subscription IDs to query for cost data.
    .OUTPUTS
        PSCustomObject with Costs (hashtable) and PeriodNames (string[]) properties.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$SubscriptionIds
    )

    Write-Output "Querying cost data..."

    # Try billing periods first; fall back to last 3 calendar months if unavailable
    # (Get-AzBillingPeriod doesn't work for all account types: PAYG, MCA, etc.)
    $periods = @()
    $costMethod = $null
    try {
        # https://learn.microsoft.com/powershell/module/az.billing/get-azbillingperiod
        Write-Output "Attempting to retrieve Azure billing periods (preferred method)..."
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
            Write-Output "[Cost Method: Billing Periods] Retrieved $($periods.Count) period(s): $($periods.Name -join ', ')"
            foreach ($p in $periods) {
                Write-Output "  - $($p.Name): $($p.StartDate) to $($p.EndDate)"
            }
        }
        else {
            Write-Output "Get-AzBillingPeriod returned no results."
        }
    }
    catch {
        Write-Warning "Get-AzBillingPeriod failed: $_"
    }

    # Fallback: generate last 3 calendar months
    if ($periods.Count -eq 0) {
        $costMethod = "CalendarMonths"
        Write-Output "[Cost Method: Calendar Months] Billing periods unavailable — using last 3 calendar months as fallback."
        Write-Output "  This can happen with PAYG, MCA, or MSDN subscription types that don't expose billing periods via the API."
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
            Write-Output "  - $($p.Name): $($p.StartDate) to $($p.EndDate)"
        }
    }

    Write-Output "Cost query method: $costMethod | Periods: $($periods.Count)"

    $periodNames = @($periods | ForEach-Object { $_.Name })

    # Costs hashtable: key = lowercase account resource ID, value = hashtable of period → cost
    $costs = @{}

    foreach ($subId in $SubscriptionIds) {
        # Get the account resource IDs for this subscription — ONLY accounts with deployments
        $subAccountIds = @($accountResults | Where-Object { $_.subscriptionId -eq $subId } | ForEach-Object { $_.id })
        if ($subAccountIds.Count -eq 0) {
            Write-Output "No CognitiveServices accounts in subscription '$subId' — skipping cost query."
            continue
        }

        foreach ($period in $periods) {
            $periodName = $period.Name
            $startDate  = $period.StartDate
            $endDate    = $period.EndDate

            Write-Output "Querying costs for subscription '$subId', period '$periodName' ($startDate to $endDate)..."

            $scope = "/subscriptions/$subId"

            # Filter by the specific ResourceId values of discovered accounts
            # This ensures we only get costs for accounts with AI model deployments,
            # not other CognitiveServices (Speech, Vision, Language, etc.)
            # https://learn.microsoft.com/powershell/module/az.costmanagement/new-azcostmanagementquerycomparisonexpressionobject
            $filterDimension = New-AzCostManagementQueryComparisonExpressionObject `
                -Name 'ResourceId' `
                -Value $subAccountIds

            $filter = New-AzCostManagementQueryFilterObject `
                -Dimensions $filterDimension

            try {
                # https://learn.microsoft.com/powershell/module/az.costmanagement/invoke-azcostmanagementquery
                $costResult = Invoke-AzCostManagementQuery `
                    -Scope $scope `
                    -Type 'ActualCost' `
                    -Timeframe 'Custom' `
                    -TimePeriodFrom $startDate `
                    -TimePeriodTo $endDate `
                    -DatasetGranularity 'None' `
                    -DatasetGrouping @(
                        @{ Type = 'Dimension'; Name = 'ResourceId' },
                        @{ Type = 'Dimension'; Name = 'MeterCategory' }
                    ) `
                    -DatasetFilter $filter `
                    -ErrorAction Stop
            }
            catch {
                Write-Warning "Cost query failed for subscription '$subId', period '$periodName': $_"
                continue
            }

            if (-not $costResult -or -not $costResult.Row) {
                Write-Output "  No cost rows returned."
                continue
            }

            Write-Output "  Returned $($costResult.Row.Count) cost row(s). Columns: $($costResult.Column.Name -join ', ')"

            # Parse cost result rows
            # Columns typically: Cost, ResourceId, ServiceName, Currency
            $columns = $costResult.Column
            $costIndex        = -1
            $resourceIdIndex  = -1
            $serviceNameIndex = -1

            for ($i = 0; $i -lt $columns.Count; $i++) {
                switch ($columns[$i].Name.ToLower()) {
                    'cost'           { $costIndex       = $i }
                    'resourceid'     { $resourceIdIndex = $i }
                    'metercategory'  { $serviceNameIndex = $i }
                    'servicename'    { if ($serviceNameIndex -lt 0) { $serviceNameIndex = $i } }
                }
            }

            if ($costIndex -lt 0 -or $resourceIdIndex -lt 0) {
                Write-Warning "Unexpected column layout in cost query results for subscription '$subId', period '$periodName'."
                continue
            }

            $periodRowCount = 0
            foreach ($row in $costResult.Row) {
                $costAmount = [decimal]$row[$costIndex]
                $rawResourceId = [string]$row[$resourceIdIndex]
                $serviceName = if ($serviceNameIndex -ge 0) { [string]$row[$serviceNameIndex] } else { 'N/A' }

                if ($costAmount -gt 0) {
                    $periodRowCount++
                    Write-Output "    $($serviceName): `$$([math]::Round($costAmount, 2)) — $rawResourceId"
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

    Write-Output "Cost query complete. Found cost data for $($costs.Count) account(s)."

    return [PSCustomObject]@{
        Costs       = $costs
        PeriodNames = $periodNames
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
        [string[]]$BillingPeriodNames
    )

    Write-Output "Building report for $($Deployments.Count) deployment(s)..."

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

        $row = [PSCustomObject]@{
            SubscriptionName = $dep.SubscriptionName
            ResourceGroup    = $dep.ResourceGroupName
            ResourceType     = $dep.ResourceType
            ResourceName     = $dep.ResourceName
            ProjectName      = $dep.ProjectName
            DeploymentName   = $dep.DeploymentName
            ModelName        = $dep.ModelName
            ModelVersion     = $dep.ModelVersion
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

    # Generate CSV content
    $csvContent = ''
    if ($reportRows.Count -gt 0) {
        $csvContent = ($reportRows | ConvertTo-Csv -NoTypeInformation) -join "`n"
    }

    # Generate HTML content
    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss UTC')
    $htmlBuilder = [System.Text.StringBuilder]::new()
    [void]$htmlBuilder.AppendLine('<!DOCTYPE html>')
    [void]$htmlBuilder.AppendLine('<html lang="en">')
    [void]$htmlBuilder.AppendLine('<head>')
    [void]$htmlBuilder.AppendLine('  <meta charset="UTF-8">')
    [void]$htmlBuilder.AppendLine("  <title>Model Hunter Report — $timestamp</title>")
    [void]$htmlBuilder.AppendLine('  <style>')
    [void]$htmlBuilder.AppendLine('    body { font-family: Segoe UI, Arial, sans-serif; margin: 20px; background: #f9f9f9; }')
    [void]$htmlBuilder.AppendLine('    h1 { color: #333; }')
    [void]$htmlBuilder.AppendLine('    table { border-collapse: collapse; width: 100%; font-size: 13px; }')
    [void]$htmlBuilder.AppendLine('    th { background: #0078d4; color: #fff; padding: 8px 10px; text-align: left; }')
    [void]$htmlBuilder.AppendLine('    td { padding: 6px 10px; border-bottom: 1px solid #ddd; }')
    [void]$htmlBuilder.AppendLine('    tr.in-use { background: #dff6dd; }')
    [void]$htmlBuilder.AppendLine('    tr.unused { background: #fde7e9; }')
    [void]$htmlBuilder.AppendLine('    tr:hover { opacity: 0.85; }')
    [void]$htmlBuilder.AppendLine('    .summary { margin-bottom: 16px; color: #555; }')
    [void]$htmlBuilder.AppendLine('  </style>')
    [void]$htmlBuilder.AppendLine('</head>')
    [void]$htmlBuilder.AppendLine('<body>')
    [void]$htmlBuilder.AppendLine("  <h1>Model Hunter Report</h1>")
    [void]$htmlBuilder.AppendLine("  <p class=`"summary`">Generated: $timestamp | Deployments: $($reportRows.Count)</p>")
    [void]$htmlBuilder.AppendLine('  <table>')

    # Header row
    [void]$htmlBuilder.AppendLine('    <thead><tr>')
    $headerColumns = @(
        'SubscriptionName', 'ResourceGroup', 'ResourceType', 'ResourceName',
        'ProjectName', 'DeploymentName', 'ModelName', 'ModelVersion',
        'SKU', 'Capacity', 'IsInUse'
    )
    foreach ($periodName in $BillingPeriodNames) {
        $headerColumns += "Cost_$periodName"
    }
    $headerColumns += 'TotalCost'

    foreach ($col in $headerColumns) {
        [void]$htmlBuilder.AppendLine("      <th>$col</th>")
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
            # Format cost columns as currency
            if ($col -like 'Cost_*' -or $col -eq 'TotalCost') {
                $value = '{0:N2}' -f [decimal]$value
            }
            # HTML-encode basic characters
            $value = [string]$value -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
            [void]$htmlBuilder.AppendLine("      <td>$value</td>")
        }
        [void]$htmlBuilder.AppendLine('    </tr>')
    }
    [void]$htmlBuilder.AppendLine('    </tbody>')
    [void]$htmlBuilder.AppendLine('  </table>')
    [void]$htmlBuilder.AppendLine('</body>')
    [void]$htmlBuilder.AppendLine('</html>')

    $htmlContent = $htmlBuilder.ToString()

    Write-Output "Report built: $($reportRows.Count) row(s), CSV length $($csvContent.Length), HTML length $($htmlContent.Length)."

    return [PSCustomObject]@{
        CsvContent  = $csvContent
        HtmlContent = $htmlContent
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

    Write-Output "Publishing reports to blob storage..."

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

        Write-Output "Uploaded CSV: $csvBlobName"

        # https://learn.microsoft.com/powershell/module/az.storage/set-azstorageblobcontent
        Set-AzStorageBlobContent `
            -File $tempHtmlPath `
            -Container $ContainerName `
            -Blob $htmlBlobName `
            -Context $storageContext `
            -Properties @{ ContentType = 'text/html' } `
            -Force `
            -ErrorAction Stop | Out-Null

        Write-Output "Uploaded HTML: $htmlBlobName"
    }
    catch {
        throw "Failed to upload report to blob storage: $_"
    }
    finally {
        # Clean up temporary files
        if (Test-Path $tempCsvPath)  { Remove-Item $tempCsvPath  -Force -ErrorAction SilentlyContinue }
        if (Test-Path $tempHtmlPath) { Remove-Item $tempHtmlPath -Force -ErrorAction SilentlyContinue }
    }

    Write-Output "Reports published to container '$ContainerName' in storage account '$storageAccountName'."
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
$costResult = Get-DeploymentCosts -SubscriptionIds $SubscriptionIds

$billingPeriodNames = if ($costResult.PeriodNames) { $costResult.PeriodNames } else { @() }
$costs = if ($costResult.Costs) { $costResult.Costs } else { @{} }

Write-Output ""
Write-Output "========================================="
Write-Output "STEP 4: Merging Data & Building Report"
Write-Output "========================================="
Write-Output "Merging $($deployments.Count) deployment(s) with cost data from $($billingPeriodNames.Count) period(s)..."
$report = Build-Report `
    -Deployments $deployments `
    -Costs $costs `
    -BillingPeriodNames $billingPeriodNames

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
        $csvFile  = Join-Path $OutputPath "model-discovery-$timestamp.csv"
        $htmlFile = Join-Path $OutputPath "model-discovery-$timestamp.html"

        [System.IO.File]::WriteAllText($csvFile, $report.CsvContent)
        [System.IO.File]::WriteAllText($htmlFile, $report.HtmlContent)

        Write-Output "Reports saved locally:"
        Write-Output "  CSV:  $csvFile"
        Write-Output "  HTML: $htmlFile"
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
