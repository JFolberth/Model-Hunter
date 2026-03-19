resource_group_name     = "rg-model-hunter-dev-eus2"
automation_account_name = "aa-model-hunter-dev-eus2"
storage_account_name    = "stmodelhunterdeveus2"
location                = "eastus2"
container_name          = "model-discovery-reports"
runbook_name            = "Model-Hunter"
schedule_frequency      = "Month"
schedule_interval       = 1

target_subscription_ids = [
  "35ce8cef-94f9-4dba-9c61-a09396fec7cf"
]

tags = {
  Environment = "Development"
  Project     = "Model-Hunter"
}
