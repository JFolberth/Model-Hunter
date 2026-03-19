variable "name" {
  description = "Name of the Automation Runbook."
  type        = string
}

variable "automation_account_id" {
  description = "Resource ID of the parent Automation Account."
  type        = string
}

variable "location" {
  description = "Azure region for the Runbook (must match the Automation Account region)."
  type        = string
}

variable "tags" {
  description = "Tags to apply to the Runbook."
  type        = map(string)
  default     = {}
}

variable "script_path" {
  description = "Local path to the PowerShell script to deploy as the Runbook content."
  type        = string
}

variable "schedule_frequency" {
  description = "Schedule frequency: Day, Week, or Month."
  type        = string
  default     = "Month"

  validation {
    condition     = contains(["Day", "Week", "Month"], var.schedule_frequency)
    error_message = "schedule_frequency must be one of: Day, Week, Month."
  }
}

variable "schedule_interval" {
  description = "Interval for the schedule (e.g., 1 = every 1 month if frequency is Month)."
  type        = number
  default     = 1
}

variable "target_subscription_ids" {
  description = "Subscription IDs passed to the Runbook as a parameter."
  type        = list(string)
}

variable "storage_account_resource_id" {
  description = "Resource ID of the Storage Account for report upload, passed to the Runbook."
  type        = string
}

variable "container_name" {
  description = "Blob container name for reports, passed to the Runbook."
  type        = string
}
