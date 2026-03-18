output "id" {
  description = "Resource ID of the Runbook."
  value       = azapi_resource.runbook.id
}

output "name" {
  description = "Name of the Runbook."
  value       = azapi_resource.runbook.name
}

output "schedule_id" {
  description = "Resource ID of the Automation Schedule."
  value       = azapi_resource.schedule.id
}

output "schedule_name" {
  description = "Name of the Automation Schedule."
  value       = azapi_resource.schedule.name
}
