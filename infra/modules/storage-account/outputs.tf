output "id" {
  description = "Resource ID of the Storage Account."
  value       = azapi_resource.storage_account.id
}

output "name" {
  description = "Name of the Storage Account."
  value       = azapi_resource.storage_account.name
}

output "blob_endpoint" {
  description = "Primary blob endpoint of the Storage Account."
  value       = azapi_resource.storage_account.output.properties.primaryEndpoints.blob
}
