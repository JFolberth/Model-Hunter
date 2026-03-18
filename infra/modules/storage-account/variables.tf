variable "name" {
  description = "Name of the Storage Account (must be globally unique, 3-24 lowercase alphanumeric)."
  type        = string
}

variable "location" {
  description = "Azure region for the Storage Account."
  type        = string
}

variable "resource_group_id" {
  description = "Resource ID of the parent resource group."
  type        = string
}

variable "container_name" {
  description = "Name of the blob container."
  type        = string
}

variable "tags" {
  description = "Tags to apply to the Storage Account."
  type        = map(string)
  default     = {}
}
