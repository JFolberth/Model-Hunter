variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "eastus2"
}

variable "resource_group_name" {
  description = "Name of the resource group."
  type        = string
}

variable "automation_account_name" {
  description = "Name of the Automation Account."
  type        = string
}

variable "storage_account_name" {
  description = "Name of the Storage Account (must be globally unique, 3-24 lowercase alphanumeric)."
  type        = string
}

variable "container_name" {
  description = "Name of the blob container for model discovery reports."
  type        = string
  default     = "model-discovery-reports"
}

variable "target_subscription_ids" {
  description = "List of subscription IDs to scan for AI model deployments."
  type        = list(string)
}

variable "tags" {
  description = "Tags to apply to all resources."
  type        = map(string)
  default     = {}
}

variable "runbook_name" {
  description = "Name of the Automation Runbook."
  type        = string
  default     = "Model-Hunter"
}
