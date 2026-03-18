output "id" {
  description = "Resource ID of the Automation Account."
  value       = azapi_resource.automation_account.id
}

output "name" {
  description = "Name of the Automation Account."
  value       = azapi_resource.automation_account.name
}

output "principal_id" {
  description = "Principal ID of the system-assigned managed identity."
  value       = azapi_resource.automation_account.identity[0].principal_id
}
