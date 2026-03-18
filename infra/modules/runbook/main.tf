terraform {
  required_providers {
    azapi = {
      source = "Azure/azapi"
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
      runbookType = "PowerShell72"
      description = "Model Hunter – discovers and reports on AI model deployments across subscriptions."
      logVerbose  = false
      logProgress = false
      draft       = {}
    }
  }
}

# Upload the PowerShell script content to the runbook draft, then publish
# https://learn.microsoft.com/rest/api/automation/runbook-draft/replace-content
resource "azapi_resource_action" "runbook_publish" {
  type        = "Microsoft.Automation/automationAccounts/runbooks@2024-10-23"
  resource_id = azapi_resource.runbook.id
  action      = "publish"
  method      = "POST"

  depends_on = [azapi_resource.runbook]
}

# https://learn.microsoft.com/azure/templates/microsoft.automation/automationaccounts/schedules
resource "azapi_resource" "schedule" {
  type      = "Microsoft.Automation/automationAccounts/schedules@2024-10-23"
  name      = "${var.name}-schedule"
  parent_id = var.automation_account_id

  body = {
    properties = {
      description = "Schedule for Model Hunter runbook"
      startTime   = var.schedule_start_time
      frequency   = var.schedule_frequency
      interval    = var.schedule_interval
      timeZone    = "UTC"
    }
  }
}

# https://learn.microsoft.com/azure/templates/microsoft.automation/automationaccounts/jobschedules
resource "azapi_resource" "job_schedule" {
  type      = "Microsoft.Automation/automationAccounts/jobSchedules@2024-10-23"
  name      = format("%s-%s-%s-%s-%s",
    substr(md5("${azapi_resource.runbook.name}-${azapi_resource.schedule.name}"), 0, 8),
    substr(md5("${azapi_resource.runbook.name}-${azapi_resource.schedule.name}"), 8, 4),
    substr(md5("${azapi_resource.runbook.name}-${azapi_resource.schedule.name}"), 12, 4),
    substr(md5("${azapi_resource.runbook.name}-${azapi_resource.schedule.name}"), 16, 4),
    substr(md5("${azapi_resource.runbook.name}-${azapi_resource.schedule.name}"), 20, 12)
  )
  parent_id = var.automation_account_id

  body = {
    properties = {
      runbook = {
        name = azapi_resource.runbook.name
      }
      schedule = {
        name = azapi_resource.schedule.name
      }
      parameters = {
        subscriptionids          = jsonencode(var.target_subscription_ids)
        storageaccountresourceid = var.storage_account_resource_id
        containername            = var.container_name
      }
    }
  }

  depends_on = [azapi_resource_action.runbook_publish]
}
