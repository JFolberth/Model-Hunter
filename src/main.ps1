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

.PARAMETER ContainerName
    Blob container name for report upload. Defaults to "model-discovery-reports".
#>

#region Parameters
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$SubscriptionIds,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$StorageAccountResourceId,

    [string]$ContainerName = "model-discovery-reports"
)
#endregion Parameters

#region Authentication
try {
    Write-Output "Authenticating with Managed Identity..."
    # https://learn.microsoft.com/powershell/module/az.accounts/connect-azaccount
    Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
    Write-Output "Authentication successful."
}
catch {
    throw "Failed to authenticate with Managed Identity: $_"
}
#endregion Authentication

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

    Write-Verbose "Querying CognitiveServices accounts via Resource Graph..."
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

    # Query 2: Get all CognitiveServices deployments
    $deploymentQuery = @"
resources
| where type =~ 'microsoft.cognitiveservices/accounts/deployments'
| project id, name, properties, sku
"@

    Write-Output "Querying CognitiveServices deployments via Resource Graph..."
    try {
        # https://learn.microsoft.com/powershell/module/az.resourcegraph/search-azgraph
        $deploymentResults = Search-AzGraph -Query $deploymentQuery -Subscription $SubscriptionIds -ErrorAction Stop
    }
    catch {
        throw "Failed to query CognitiveServices deployments: $_"
    }

    Write-Output "Found $($deploymentResults.Count) deployment(s). Parsing resource details..."

    $deployments = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($dep in $deploymentResults) {
        $resourceId = $dep.id

        # Parse the resource ID to extract components
        # Patterns:
        #   /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.CognitiveServices/accounts/{name}/projects/{project}/deployments/{deployment}
        #   /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.CognitiveServices/accounts/{name}/deployments/{deployment}
        $segments = $resourceId -split '/'

        $subId = $null
        $rgName = $null
        $accountName = $null
        $projectName = $null
        $deploymentName = $null

        for ($i = 0; $i -lt $segments.Count; $i++) {
            switch ($segments[$i].ToLower()) {
                'subscriptions'  { $subId          = $segments[$i + 1] }
                'resourcegroups' { $rgName         = $segments[$i + 1] }
                'accounts'       { $accountName    = $segments[$i + 1] }
                'projects'       { $projectName    = $segments[$i + 1] }
                'deployments'    { $deploymentName = $segments[$i + 1] }
            }
        }

        # Build the parent account resource ID for cost matching
        $accountResourceId = "/subscriptions/$subId/resourceGroups/$rgName/providers/Microsoft.CognitiveServices/accounts/$accountName"

        # Determine the account kind from our lookup
        $accountKind = $accountKindMap[$accountResourceId.ToLower()]

        # Classification rules (in order):
        # 1. kind == "OpenAI" → "OpenAI Service"
        # 2. Resource ID contains /projects/ → "Foundry (Project)"
        # 3. Otherwise → "Foundry (Hub/Legacy)"
        if ($accountKind -eq 'OpenAI') {
            $resourceType = 'OpenAI Service'
        }
        elseif ($resourceId -match '/projects/') {
            $resourceType = 'Foundry (Project)'
        }
        else {
            $resourceType = 'Foundry (Hub/Legacy)'
        }

        # Extract model info from properties
        $modelName    = $null
        $modelVersion = $null
        if ($dep.properties -and $dep.properties.model) {
            $modelName    = $dep.properties.model.name
            $modelVersion = $dep.properties.model.version
        }

        # Extract SKU info
        $skuName  = $null
        $capacity = $null
        if ($dep.sku) {
            $skuName  = $dep.sku.name
            $capacity = $dep.sku.capacity
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
            AccountResourceId = $accountResourceId.ToLower()
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

    Write-Output "Querying cost data for the last 3 billing periods..."

    # Get the last 3 billing periods
    try {
        # https://learn.microsoft.com/powershell/module/az.billing/get-azbillingperiod
        $billingPeriods = Get-AzBillingPeriod -MaxCount 3 -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to retrieve billing periods: $_. Cost data will be unavailable."
        return [PSCustomObject]@{
            Costs       = @{}
            PeriodNames = @()
        }
    }

    if (-not $billingPeriods -or $billingPeriods.Count -eq 0) {
        Write-Warning "No billing periods found. Cost data will be unavailable."
        return [PSCustomObject]@{
            Costs       = @{}
            PeriodNames = @()
        }
    }

    $periodNames = @($billingPeriods | ForEach-Object { $_.Name })
    Write-Output "Billing periods: $($periodNames -join ', ')"

    # Costs hashtable: key = lowercase account resource ID, value = hashtable of period → cost
    $costs = @{}

    foreach ($subId in $SubscriptionIds) {
        foreach ($period in $billingPeriods) {
            $periodName = $period.Name
            $startDate  = $period.BillingPeriodStartDate.ToString('yyyy-MM-dd')
            $endDate    = $period.BillingPeriodEndDate.ToString('yyyy-MM-dd')

            Write-Output "Querying costs for subscription '$subId', period '$periodName' ($startDate to $endDate)..."

            $scope = "/subscriptions/$subId"

            # Build the filter: ServiceName dimension containing Foundry or OpenAI
            $filterFoundry = New-AzCostManagementQueryComparisonExpressionObject `
                -Name 'ServiceName' `
                -Operator 'In' `
                -Value @('Azure AI Foundry Models', 'Azure OpenAI Service')

            $filterDimension = New-AzCostManagementQueryFilterObject `
                -Dimension $filterFoundry

            # Build dataset groupings
            $groupByResourceId = New-AzCostManagementQueryGroupingObject `
                -Type 'Dimension' `
                -Name 'ResourceId'

            $groupByServiceName = New-AzCostManagementQueryGroupingObject `
                -Type 'Dimension' `
                -Name 'ServiceName'

            # Build the time period
            $timePeriod = New-AzCostManagementQueryTimePeriodObject `
                -From $startDate `
                -To $endDate

            try {
                # https://learn.microsoft.com/powershell/module/az.costmanagement/invoke-azcostmanagementquery
                $costResult = Invoke-AzCostManagementQuery `
                    -Scope $scope `
                    -Type 'ActualCost' `
                    -Timeframe 'Custom' `
                    -TimePeriod $timePeriod `
                    -DatasetGranularity 'None' `
                    -DatasetGrouping @($groupByResourceId, $groupByServiceName) `
                    -DatasetFilter $filterDimension `
                    -ErrorAction Stop
            }
            catch {
                Write-Warning "Cost query failed for subscription '$subId', period '$periodName': $_"
                continue
            }

            if (-not $costResult -or -not $costResult.Row) {
                Write-Output "No cost rows returned for subscription '$subId', period '$periodName'."
                continue
            }

            # Parse cost result rows
            # Columns typically: Cost, ResourceId, ServiceName, Currency
            $columns = $costResult.Column
            $costIndex       = -1
            $resourceIdIndex = -1

            for ($i = 0; $i -lt $columns.Count; $i++) {
                switch ($columns[$i].Name.ToLower()) {
                    'cost'       { $costIndex       = $i }
                    'resourceid' { $resourceIdIndex = $i }
                }
            }

            if ($costIndex -lt 0 -or $resourceIdIndex -lt 0) {
                Write-Warning "Unexpected column layout in cost query results for subscription '$subId', period '$periodName'."
                continue
            }

            foreach ($row in $costResult.Row) {
                $costAmount = [decimal]$row[$costIndex]
                $rawResourceId = [string]$row[$resourceIdIndex]

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
        [AllowEmptyCollection()]
        [string[]]$BillingPeriodNames
    )

    Write-Output "Building report for $($Deployments.Count) deployment(s)..."

    if (-not $Costs) { $Costs = @{} }

    $reportRows = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($dep in $Deployments) {
        $accountCosts = $Costs[$dep.AccountResourceId]

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
Write-Output "Starting Model Hunter..."

$deployments = Get-ModelDeployments -SubscriptionIds $SubscriptionIds

$costResult = Get-DeploymentCosts -SubscriptionIds $SubscriptionIds

$report = Build-Report `
    -Deployments $deployments `
    -Costs $costResult.Costs `
    -BillingPeriodNames $costResult.PeriodNames

Publish-Report `
    -CsvContent $report.CsvContent `
    -HtmlContent $report.HtmlContent `
    -StorageAccountResourceId $StorageAccountResourceId `
    -ContainerName $ContainerName

Write-Output "Model Hunter complete. Found $($deployments.Count) deployment(s)."
#endregion Main Execution
