# https://learn.microsoft.com/azure/templates/microsoft.resources/resourcegroups
resource "azapi_resource" "resource_group" {
  type      = "Microsoft.Resources/resourceGroups@2024-11-01"
  name      = var.name
  location  = var.location
  parent_id = "/subscriptions/${data.azapi_client_config.current.subscription_id}"
  tags      = var.tags
}

data "azapi_client_config" "current" {}
