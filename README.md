# Model Hunter

Model Hunter discovers all deployed Azure AI Foundry and OpenAI models across Azure subscriptions, correlates them with cost data from Azure Cost Management, and generates CSV + HTML reports for Azure administrators. It answers the question: **what models are deployed, where, and are they being used?** The tool runs as an Azure Automation Runbook on a schedule, scanning multiple subscriptions via Managed Identity, and uploads reports to Azure Blob Storage.

## Prerequisites

| Requirement | Version |
|---|---|
| [Terraform](https://www.terraform.io/) | >= 1.5 |
| [Docker](https://www.docker.com/) | Latest (for Terraform MCP server) |
| [PowerShell](https://learn.microsoft.com/powershell/) | 7.2+ |
| Az PowerShell Modules | Az.Accounts, Az.ResourceGraph, Az.CostManagement, Az.Storage, Az.Billing |

## Quick Start

1. Clone the repository:

   ```bash
   git clone <repo-url>
   cd Model-Hunter
   ```

2. Deploy the infrastructure:

   ```bash
   cd infra
   terraform init
   terraform plan
   terraform apply
   ```

3. The Runbook runs on schedule via Azure Automation. No further action is required after deployment.

## Local Testing

You can run the discovery script locally against your own subscriptions:

```powershell
Connect-AzAccount
./src/main.ps1 -SubscriptionIds @("sub-id") `
  -StorageAccountResourceId "/subscriptions/.../storageAccounts/..." `
  -ContainerName "model-discovery-reports"
```

> **Note:** When running locally, report output is written to the `output/` directory, which is gitignored.

See [`parameters.sample.json`](parameters.sample.json) for an example of the required parameter values.

## Documentation

- [Architecture](docs/architecture.md) — infrastructure components, data flow, and authentication model
- [Runbook Process](docs/runbook-process.md) — step-by-step walkthrough of the Runbook pipeline

## Required Azure Permissions

The Automation Account's System-Assigned Managed Identity requires the following role assignments:

| Role | Scope | Purpose |
|---|---|---|
| **Reader** | Target subscription(s) | Read resources via Azure Resource Graph |
| **Cost Management Reader** | Target subscription(s) | Query cost data via Cost Management API |
| **Storage Blob Data Contributor** | Storage account | Upload CSV and HTML reports to blob storage |

These role assignments are provisioned automatically by the `role_assignments` Terraform module.
