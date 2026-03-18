# Model Hunter

Model Hunter discovers all deployed Azure AI Foundry and OpenAI models across Azure subscriptions, correlates them with cost data from Azure Cost Management, and generates CSV + HTML reports for Azure administrators. It answers the question: **what models are deployed, where, and are they being used?** The tool runs as an Azure Automation Runbook on a schedule, scanning multiple subscriptions via Managed Identity, and uploads reports to Azure Blob Storage.

## Prerequisites

| Requirement | Version |
|---|---|
| [PowerShell](https://learn.microsoft.com/powershell/) | 7.2+ |
| Az PowerShell Modules | Az.Accounts, Az.ResourceGraph, Az.CostManagement, Az.Storage, Az.Billing |
| [Terraform](https://www.terraform.io/) | >= 1.6 |
| [Docker](https://www.docker.com/) | Latest (for Terraform MCP server) |

> **Tip:** Open this repo in the [Dev Container](.devcontainer/devcontainer.json) to get all prerequisites pre-installed.

## Local Testing

Run the discovery script locally before deploying to Azure:

1. Install the required Az modules (if not using the Dev Container):

   ```powershell
   Install-Module -Name Az.Accounts, Az.ResourceGraph, Az.CostManagement, Az.Storage, Az.Billing -Force -Scope CurrentUser
   ```

2. Authenticate:

   ```powershell
   Connect-AzAccount
   ```

3. Run the script:

   ```powershell
   ./src/main.ps1 -SubscriptionIds @("sub-id") `
     -StorageAccountResourceId "/subscriptions/.../storageAccounts/..." `
     -ContainerName "model-discovery-reports"
   ```

> **Note:** When running locally, report output is written to the `output/` directory, which is gitignored.

## Infrastructure Deployment

1. Clone the repository:

   ```bash
   git clone <repo-url>
   cd Model-Hunter
   ```

2. Configure your variables:

   ```bash
   cd infra
   cp terraform.tfvars.sample terraform.tfvars
   ```

   Edit `terraform.tfvars` with your values — subscription IDs, resource names, schedule, and tags.

3. Deploy the infrastructure:

   ```bash
   terraform init
   terraform plan     # Review changes before applying
   terraform apply
   ```

4. The Runbook runs automatically on the configured schedule (default: monthly). No further action is required after deployment.

## Schedule Configuration

The Runbook schedule is configurable via `terraform.tfvars`:

| Variable | Default | Description |
|---|---|---|
| `schedule_frequency` | `Month` | `Day`, `Week`, or `Month` |
| `schedule_interval` | `1` | Run every N days/weeks/months |
| `schedule_start_time` | — | ISO 8601 datetime for the first run (e.g., `2026-04-01T02:00:00Z`) |

## Documentation

- [Architecture](docs/architecture.md) — infrastructure components, data flow, and authentication model
- [Runbook Process](docs/runbook-process.md) — step-by-step walkthrough of the Runbook pipeline

## Required Azure Permissions

### Terraform Deployer

The user or service principal running `terraform apply` needs:

| Role | Scope | Purpose |
|---|---|---|
| **Contributor** | Resource group (or subscription) | Create Automation Account, Storage Account, Runbook |
| **User Access Administrator** | Target subscription(s) | Create role assignments for the Managed Identity |

### Runbook Managed Identity

The Automation Account's System-Assigned Managed Identity requires the following role assignments (provisioned automatically by the `role-assignments` Terraform module):

| Role | Scope | Purpose |
|---|---|---|
| **Reader** | Target subscription(s) | Read resources via Azure Resource Graph |
| **Cost Management Reader** | Target subscription(s) | Query cost data via Cost Management API |
| **Storage Blob Data Contributor** | Storage account | Upload CSV and HTML reports to blob storage |
