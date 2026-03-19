terraform {
  required_version = ">= 1.6"

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
  }

  backend "azurerm" {
    # Partial config — populated at init time via -backend-config flags:
    #   resource_group_name  = "rg-terraformstate-dev-eus"
    #   storage_account_name = "saterraformstatedeveus"
    #   container_name       = "tfstate"
    #   key                  = "model-hunter-{env}.tfstate"
    # https://learn.microsoft.com/azure/developer/terraform/store-state-in-azure-storage
  }
}

provider "azapi" {}
