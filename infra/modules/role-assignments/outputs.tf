output "role_assignment_ids" {
  description = "Map of role assignment keys to their resource IDs."
  value       = { for k, v in azapi_resource.role_assignment : k => v.id }
}
