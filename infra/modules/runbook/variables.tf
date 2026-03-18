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
