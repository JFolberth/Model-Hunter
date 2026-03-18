variable "name" {
  description = "Name of the Automation Account."
  type        = string
}

variable "location" {
  description = "Azure region for the Automation Account."
  type        = string
}

variable "resource_group_id" {
  description = "Resource ID of the parent resource group."
  type        = string
}

variable "tags" {
  description = "Tags to apply to the Automation Account."
  type        = map(string)
  default     = {}
}
