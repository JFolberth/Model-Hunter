# Prod environment configuration — update values before first deployment.

resource_group_name     = "rg-model-hunter-prod-eus2"
automation_account_name = "aa-model-hunter-prod-eus2"
storage_account_name    = "stmodelhunterprodeus2"
location                = "eastus2"
container_name          = "model-discovery-reports"
runbook_name            = "Model-Hunter"
schedule_frequency      = "Month"
schedule_interval       = 1

tags = {
  Environment = "Production"
  Project     = "Model-Hunter"
}
