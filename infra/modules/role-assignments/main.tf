terraform {
  required_providers {
    azapi = {
      source = "Azure/azapi"
    }
  }
}

# https://learn.microsoft.com/azure/templates/microsoft.authorization/roleassignments

locals {
  # Build a flat map of subscription-level role assignments
  subscription_roles = flatten([
    for sub_id in var.target_subscription_ids : [
      {
        key                = "reader-${sub_id}"
        scope              = "/subscriptions/${sub_id}"
        role_definition_id = "/subscriptions/${sub_id}/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
      },
      {
        key                = "cost-reader-${sub_id}"
        scope              = "/subscriptions/${sub_id}"
        role_definition_id = "/subscriptions/${sub_id}/providers/Microsoft.Authorization/roleDefinitions/72fafb9e-0641-4937-9268-a91bfd8191a3"
      }
    ]
  ])

  # Extract the subscription from the storage account resource ID
  storage_subscription_id = regex("^/subscriptions/([^/]+)", var.storage_account_id)[0]

  # Merge all role assignments into a single map keyed by a friendly name
  all_role_assignments = merge(
    { for r in local.subscription_roles : r.key => r },
    {
      "storage-blob-contributor" = {
        key                = "storage-blob-contributor"
        scope              = var.storage_account_id
        role_definition_id = "/subscriptions/${local.storage_subscription_id}/providers/Microsoft.Authorization/roleDefinitions/ba92f5b4-2d11-453d-a403-e96b0029c9fe"
      }
    }
  )
}

resource "azapi_resource" "role_assignment" {
  for_each = local.all_role_assignments

  type = "Microsoft.Authorization/roleAssignments@2022-04-01"

  # Deterministic GUID derived from principal + scope + role so re-applies are idempotent
  name      = format("%s-%s-%s-%s-%s",
    substr(md5("${var.principal_id}-${each.value.scope}-${each.value.role_definition_id}"), 0, 8),
    substr(md5("${var.principal_id}-${each.value.scope}-${each.value.role_definition_id}"), 8, 4),
    substr(md5("${var.principal_id}-${each.value.scope}-${each.value.role_definition_id}"), 12, 4),
    substr(md5("${var.principal_id}-${each.value.scope}-${each.value.role_definition_id}"), 16, 4),
    substr(md5("${var.principal_id}-${each.value.scope}-${each.value.role_definition_id}"), 20, 12)
  )
  parent_id = each.value.scope

  body = {
    properties = {
      principalId      = var.principal_id
      principalType    = "ServicePrincipal"
      roleDefinitionId = each.value.role_definition_id
    }
  }
}
