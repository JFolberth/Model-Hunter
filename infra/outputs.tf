output "resource_group_id" {
  description = "Resource ID of the resource group."
  value       = module.resource_group.id
}

output "automation_account_id" {
  description = "Resource ID of the Automation Account."
  value       = module.automation_account.id
}

output "automation_account_principal_id" {
  description = "Principal ID of the Automation Account system-assigned managed identity."
  value       = module.automation_account.principal_id
}

output "storage_account_id" {
  description = "Resource ID of the Storage Account."
  value       = module.storage_account.id
}

output "storage_blob_endpoint" {
  description = "Primary blob endpoint of the Storage Account."
  value       = module.storage_account.blob_endpoint
}
