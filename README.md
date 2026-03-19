# Model Hunter

Model Hunter discovers all deployed Azure AI Foundry and OpenAI models across Azure subscriptions, correlates them with cost data from Azure Cost Management, and generates CSV + HTML reports for Azure administrators. It answers the question: **what models are deployed, where, and are they being used?** The tool runs as an Azure Automation Runbook on a schedule, scanning multiple subscriptions via Managed Identity, and uploads reports to Azure Blob Storage.

## Features

- **Multi-subscription scanning** — discover model deployments across multiple Azure subscriptions in a single run
- **CognitiveServices account detection** — identifies all AIServices and OpenAI accounts via Azure Resource Graph
- **Deployment inventory** — lists every model deployment with name, version, SKU, capacity, and deployment type
- **Resource classification** — distinguishes Foundry vs OpenAI Service accounts, maps Foundry projects
- **Gateway detection** — identifies models behind API gateways (APIM or third-party) by comparing the account endpoint against standard Azure patterns; shows the gateway URL in the report
- **Model retirement tracking** — queries the Azure Models API for lifecycle status and retirement dates per model version
- **Cost analysis** — queries Azure Cost Management for the last 3 billing periods (or calendar months as fallback), correlates costs to specific accounts
- **Usage determination** — flags each deployment as "In Use" or "Unused" based on whether it has any associated cost
- **Multi-currency support** — costs are reported in the customer's billing currency (USD, EUR, GBP, etc.) as returned by the Cost Management API
- **HTML dashboard** — summary cards (total deployments, in-use count, retiring models, gateway count, total cost) plus a detailed table with conditional formatting
- **CSV reports** — detail CSV with all deployment data + separate summary CSV with key metrics
- **Local & cloud output** — save reports locally during development or upload to Azure Blob Storage in production

## Prerequisites

| Requirement | Version |
|---|---|
| [PowerShell](https://learn.microsoft.com/powershell/) | 7.4+ |
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
   ./src/ModelHunter.ps1 -SubscriptionIds "sub-id-1,sub-id-2"
   ```

   Reports are saved to the `output/` directory (gitignored). To upload directly to blob storage instead, add the `-StorageAccountResourceId` parameter:

   ```powershell
   ./src/ModelHunter.ps1 -SubscriptionIds "sub-id" `
     -StorageAccountResourceId "/subscriptions/.../storageAccounts/myaccount"
   ```

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
