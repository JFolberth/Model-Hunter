output "id" {
  description = "Resource ID of the resource group."
  value       = azapi_resource.resource_group.id
}

output "name" {
  description = "Name of the resource group."
  value       = azapi_resource.resource_group.name
}
