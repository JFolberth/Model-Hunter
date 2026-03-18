variable "principal_id" {
  description = "Principal ID of the managed identity to assign roles to."
  type        = string
}

variable "target_subscription_ids" {
  description = "List of subscription IDs that the identity should be able to read."
  type        = list(string)
}

variable "storage_account_id" {
  description = "Resource ID of the Storage Account for the blob contributor role."
  type        = string
}
