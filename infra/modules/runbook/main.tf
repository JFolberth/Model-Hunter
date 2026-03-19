terraform {
  required_version = ">= 1.6"
  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# https://learn.microsoft.com/azure/templates/microsoft.automation/automationaccounts/runtimeenvironments
resource "azapi_resource" "runtime_environment" {
  type      = "Microsoft.Automation/automationAccounts/runtimeEnvironments@2024-10-23"
  name      = "PowerShell-74"
  location  = var.location
  parent_id = var.automation_account_id

  body = {
    properties = {
      runtime = {
        language = "PowerShell"
        version  = "7.4"
      }
      defaultPackages = {
        Az = "12.3.0"
      }
      description = "PowerShell 7.4 runtime for Model Hunter with required Az modules"
    }
  }
}

# Az 12.3.0 (defaultPackages above) bundles Az.Accounts, Az.Storage, and Az.ResourceGraph.
# Do NOT add those as separate packages — it causes version conflicts ("module could not
# be loaded"). Az.CostManagement is NOT bundled and must be installed separately.

# https://learn.microsoft.com/azure/templates/microsoft.automation/automationaccounts/runtimeenvironments/packages
resource "azapi_resource" "package_az_costmanagement" {
  type      = "Microsoft.Automation/automationAccounts/runtimeEnvironments/packages@2024-10-23"
  name      = "Az.CostManagement"
  parent_id = azapi_resource.runtime_environment.id

  body = {
    properties = {
      contentLink = {
        uri = "https://www.powershellgallery.com/api/v2/package/Az.CostManagement"
      }
    }
  }
}

# https://learn.microsoft.com/azure/templates/microsoft.automation/automationaccounts/runbooks
resource "azapi_resource" "runbook" {
  type      = "Microsoft.Automation/automationAccounts/runbooks@2024-10-23"
  name      = var.name
  location  = var.location
  parent_id = var.automation_account_id
  tags      = var.tags

  body = {
    properties = {
      runbookType        = "PowerShell"
      runtimeEnvironment = azapi_resource.runtime_environment.name
      description        = "Model Hunter – discovers and reports on AI model deployments across subscriptions."
      logVerbose         = true
      logProgress        = true
      draft              = {}
    }
  }

  depends_on = [
    azapi_resource.runtime_environment,
    azapi_resource.package_az_costmanagement
  ]
}

# Upload the PowerShell script content to the runbook draft and publish it.
# azapi_resource_action requires an HCL object body (azapi 2.0+), but the
# draft/content endpoint expects raw text. We use a local-exec provisioner
# to call the Azure REST API directly via az cli.
# https://learn.microsoft.com/rest/api/automation/runbook-draft/replace-content
resource "terraform_data" "runbook_content" {
  triggers_replace = [
    filesha256(var.script_path),
    azapi_resource.runbook.id
  ]

  provisioner "local-exec" {
    interpreter = ["pwsh", "-Command"]
    command     = <<-EOT
      az rest --method PUT --url "https://management.azure.com${azapi_resource.runbook.id}/draft/content?api-version=2024-10-23" --headers "Content-Type=text/powershell" --body "@${replace(var.script_path, "\\", "/")}"
      if ($LASTEXITCODE -ne 0) { throw "Failed to upload runbook draft content" }
      az rest --method POST --url "https://management.azure.com${azapi_resource.runbook.id}/publish?api-version=2024-10-23"
      if ($LASTEXITCODE -ne 0) { throw "Failed to publish runbook" }
    EOT
  }

  depends_on = [azapi_resource.runbook]
}

# Compute a future start time at 02:00 UTC appropriate for the schedule frequency.
# plantimestamp() is evaluated at plan time and is stable within a single plan/apply cycle.
locals {
  plan_year  = tonumber(formatdate("YYYY", plantimestamp()))
  plan_month = tonumber(formatdate("M", plantimestamp()))
  next_month = local.plan_month == 12 ? 1 : local.plan_month + 1
  next_year  = local.plan_month == 12 ? local.plan_year + 1 : local.plan_year
  today_base = "${formatdate("YYYY-MM-DD", plantimestamp())}T02:00:00Z"

  schedule_start_time = (
    var.schedule_frequency == "Day" ? timeadd(local.today_base, "24h") :
    var.schedule_frequency == "Week" ? timeadd(local.today_base, "168h") :
    format("%04d-%02d-01T02:00:00Z", local.next_year, local.next_month)
  )
}

# https://learn.microsoft.com/azure/templates/microsoft.automation/automationaccounts/schedules
resource "azapi_resource" "schedule" {
  type      = "Microsoft.Automation/automationAccounts/schedules@2024-10-23"
  name      = "${var.name}-schedule"
  parent_id = var.automation_account_id

  body = {
    properties = {
      description = "Schedule for Model Hunter runbook"
      startTime   = local.schedule_start_time
      frequency   = var.schedule_frequency
      interval    = var.schedule_interval
      timeZone    = "UTC"
    }
  }

  lifecycle {
    ignore_changes = [body.properties.startTime]
  }
}

# Stable UUID for the job schedule — regenerates only when the runbook or schedule changes.
resource "random_uuid" "job_schedule_id" {
  keepers = {
    runbook_name  = azapi_resource.runbook.name
    schedule_name = azapi_resource.schedule.name
  }
}

# https://learn.microsoft.com/azure/templates/microsoft.automation/automationaccounts/jobschedules
# Uses local-exec instead of azapi_resource because Azure Automation jobSchedules
# have eventual consistency — the read-back GET after a successful PUT often returns
# 404 before the resource fully propagates, which causes azapi_resource to fail.
resource "terraform_data" "job_schedule" {
  triggers_replace = [
    azapi_resource.runbook.name,
    azapi_resource.schedule.name,
    jsonencode(var.target_subscription_ids),
    var.storage_account_resource_id,
    var.container_name
  ]

  provisioner "local-exec" {
    interpreter = ["pwsh", "-Command"]
    command     = <<-EOT
      $guid = "${random_uuid.job_schedule_id.result}"
      $body = @{
        properties = @{
          runbook    = @{ name = "${azapi_resource.runbook.name}" }
          schedule   = @{ name = "${azapi_resource.schedule.name}" }
          parameters = @{
            subscriptionids          = '${jsonencode(var.target_subscription_ids)}'
            storageaccountresourceid = '${var.storage_account_resource_id}'
            containername            = '${var.container_name}'
          }
        }
      } | ConvertTo-Json -Depth 10 -Compress
      az rest --method PUT `
        --url "https://management.azure.com${var.automation_account_id}/jobSchedules/$($guid)?api-version=2024-10-23" `
        --body $body
      if ($LASTEXITCODE -ne 0) { throw "Failed to create job schedule" }
      Write-Host "Created job schedule $guid"
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-Command"]
    command     = <<-EOT
      Write-Host "Skipping job schedule destroy (cleaned up with schedule deletion)"
    EOT
  }

  depends_on = [terraform_data.runbook_content]
}
