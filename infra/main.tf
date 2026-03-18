module "resource_group" {
  source = "./modules/resource-group"

  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

module "automation_account" {
  source = "./modules/automation-account"

  name              = var.automation_account_name
  location          = var.location
  resource_group_id = module.resource_group.id
  tags              = var.tags
}

module "storage_account" {
  source = "./modules/storage-account"

  name              = var.storage_account_name
  location          = var.location
  resource_group_id = module.resource_group.id
  container_name    = var.container_name
  tags              = var.tags
}

module "runbook" {
  source = "./modules/runbook"

  name                        = var.runbook_name
  automation_account_id       = module.automation_account.id
  location                    = var.location
  tags                        = var.tags
  script_path                 = "${path.module}/../src/ModelHunter.ps1"
  schedule_frequency          = var.schedule_frequency
  schedule_interval           = var.schedule_interval
  schedule_start_time         = var.schedule_start_time
  target_subscription_ids     = var.target_subscription_ids
  storage_account_resource_id = module.storage_account.id
  container_name              = var.container_name
}

module "role_assignments" {
  source = "./modules/role-assignments"

  principal_id            = module.automation_account.principal_id
  target_subscription_ids = var.target_subscription_ids
  storage_account_id      = module.storage_account.id
}
