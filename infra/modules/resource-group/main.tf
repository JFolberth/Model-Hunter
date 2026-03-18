terraform {
  required_providers {
    azapi = {
      source = "Azure/azapi"
    }
  }
}

# https://learn.microsoft.com/azure/templates/microsoft.resources/resourcegroups
resource "azapi_resource" "resource_group" {
  type      = "Microsoft.Resources/resourceGroups@2024-03-01"
  name      = var.name
  location  = var.location
  parent_id = "/subscriptions/${data.azapi_client_config.current.subscription_id}"
  tags      = var.tags
}

data "azapi_client_config" "current" {}
