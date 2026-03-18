terraform {
  required_providers {
    azapi = {
      source = "Azure/azapi"
    }
  }
}

# https://learn.microsoft.com/azure/templates/microsoft.automation/automationaccounts/runbooks
resource "azapi_resource" "runbook" {
  type      = "Microsoft.Automation/automationAccounts/runbooks@2023-11-01"
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
