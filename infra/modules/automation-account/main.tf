terraform {
  required_providers {
    azapi = {
      source = "Azure/azapi"
    }
  }
}

# https://learn.microsoft.com/azure/templates/microsoft.automation/automationaccounts
resource "azapi_resource" "automation_account" {
  type      = "Microsoft.Automation/automationAccounts@2023-11-01"
  name      = var.name
  location  = var.location
  parent_id = var.resource_group_id
  tags      = var.tags

  identity {
    type = "SystemAssigned"
  }

  body = {
    properties = {
      sku = {
        name = "Basic"
      }
    }
  }
}
