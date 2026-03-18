terraform {
  required_providers {
    azapi = {
      source = "Azure/azapi"
    }
  }
}

# https://learn.microsoft.com/azure/templates/microsoft.storage/storageaccounts
resource "azapi_resource" "storage_account" {
  type      = "Microsoft.Storage/storageAccounts@2023-05-01"
  name      = var.name
  location  = var.location
  parent_id = var.resource_group_id
  tags      = var.tags

  body = {
    kind = "StorageV2"
    sku = {
      name = "Standard_LRS"
    }
    properties = {
      minimumTlsVersion = "TLS1_2"
    }
  }

  response_export_values = ["properties.primaryEndpoints"]
}

# https://learn.microsoft.com/azure/templates/microsoft.storage/storageaccounts/blobservices/containers
resource "azapi_resource" "blob_container" {
  type      = "Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01"
  name      = var.container_name
  parent_id = "${azapi_resource.storage_account.id}/blobServices/default"

  body = {
    properties = {
      publicAccess = "None"
    }
  }
}
