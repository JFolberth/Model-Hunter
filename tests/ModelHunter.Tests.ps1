BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '..' 'src' 'ModelHunter.ps1'
}

Describe 'ModelHunter.ps1' {

    Context 'Script Parsing' {
        It 'should parse without errors' {
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile(
                $scriptPath, [ref]$null, [ref]$errors
            )
            $errors.Count | Should -Be 0
        }
    }

    Context 'SubscriptionIds Parsing' {
        BeforeAll {
            # Dot-source the script to get the parsing logic
            # We mock Connect-AzAccount and other Az commands to prevent actual Azure calls
            function Connect-AzAccount { }
            function Get-AzContext { return @{ Account = @{ Id = 'test' }; Tenant = @{ Id = 'test' }; Subscription = @{ Name = 'test'; Id = 'test' } } }
            function Get-AzSubscription { return @{ Name = 'TestSub'; State = 'Enabled' } }
            function Get-Module { return @{ Name = 'Az.Accounts'; Version = '1.0' } }
            function New-AzStorageContext { }
            function Get-AzStorageContainer { }
        }

        It 'should parse comma-separated subscription IDs' {
            $input = "sub1,sub2,sub3"
            $result = @()
            if ($input.StartsWith('[')) {
                $result = ($input | ConvertFrom-Json)
            } else {
                $result = $input -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            }
            $result.Count | Should -Be 3
            $result[0] | Should -Be 'sub1'
            $result[2] | Should -Be 'sub3'
        }

        It 'should parse JSON array subscription IDs' {
            $input = '["sub1","sub2"]'
            $result = @()
            if ($input.StartsWith('[')) {
                $result = ($input | ConvertFrom-Json)
            } else {
                $result = $input -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            }
            $result.Count | Should -Be 2
            $result[0] | Should -Be 'sub1'
        }

        It 'should parse single subscription ID' {
            $input = "single-sub-id"
            $result = @()
            if ($input.StartsWith('[')) {
                $result = @($input | ConvertFrom-Json)
            } else {
                $result = @($input -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            }
            $result.Count | Should -Be 1
            $result[0] | Should -Be 'single-sub-id'
        }

        It 'should trim whitespace from comma-separated IDs' {
            $input = " sub1 , sub2 , sub3 "
            $result = $input -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            $result.Count | Should -Be 3
            $result[0] | Should -Be 'sub1'
        }
    }

    Context 'Resource Classification Logic' {
        It 'should classify OpenAI accounts correctly' {
            $kind = 'OpenAI'
            $projectName = $null
            $type = if ($kind -eq 'OpenAI') { 'OpenAI Service' } else { 'Foundry' }
            $type | Should -Be 'OpenAI Service'
        }

        It 'should classify AIServices accounts as Foundry' {
            $kind = 'AIServices'
            $type = if ($kind -eq 'OpenAI') { 'OpenAI Service' } else { 'Foundry' }
            $type | Should -Be 'Foundry'
        }
    }

    Context 'Project Name Extraction' {
        It 'should extract project name from resource ID' {
            $id = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.CognitiveServices/accounts/acct1/projects/myproject'
            $projectName = $null
            if ($id -match '(?i)/projects/([^/]+)') {
                $projectName = $Matches[1]
            }
            $projectName | Should -Be 'myproject'
        }

        It 'should return null when no project in resource ID' {
            $id = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.CognitiveServices/accounts/acct1/deployments/dep1'
            $projectName = $null
            if ($id -match '(?i)/projects/([^/]+)') {
                $projectName = $Matches[1]
            }
            $projectName | Should -BeNullOrEmpty
        }
    }

    Context 'Retirement Date Formatting' {
        It 'should format retirement date as yyyy-MM' {
            $date = '2026-10-14T00:00:00Z'
            $formatted = ([datetime]$date).ToString('yyyy-MM')
            $formatted | Should -Be '2026-10'
        }

        It 'should handle null retirement date' {
            $date = $null
            $result = $null
            if ($date) {
                try { $result = ([datetime]$date).ToString('yyyy-MM') } catch { $result = [string]$date }
            }
            $result | Should -BeNullOrEmpty
        }
    }

    Context 'Gateway Detection Logic' {
        BeforeAll {
            # Extract the Get-GatewayUrl function from the script without executing the main block.
            # Parse the script AST and evaluate only the function definition.
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
            $funcAst = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Get-GatewayUrl' }, $true)
            if ($funcAst.Count -eq 0) { throw 'Get-GatewayUrl function not found in script' }
            . ([scriptblock]::Create($funcAst[0].Extent.Text))
        }

        It 'should return blank for standard OpenAI endpoint' {
            $result = Get-GatewayUrl -EndpointUrl 'https://my-openai.openai.azure.com'
            $result | Should -Be ''
        }

        It 'should return blank for standard OpenAI endpoint with trailing slash' {
            $result = Get-GatewayUrl -EndpointUrl 'https://my-openai.openai.azure.com/'
            $result | Should -Be ''
        }

        It 'should return blank for standard CognitiveServices endpoint' {
            $result = Get-GatewayUrl -EndpointUrl 'https://my-resource.cognitiveservices.azure.com'
            $result | Should -Be ''
        }

        It 'should return blank for CognitiveServices endpoint with different resource name' {
            # Project endpoint may reference a different CognitiveServices account
            $result = Get-GatewayUrl -EndpointUrl 'https://ais-pdfgptdemoext-dev-eus.cognitiveservices.azure.com'
            $result | Should -Be ''
        }

        It 'should return blank for standard AI Services endpoint' {
            $result = Get-GatewayUrl -EndpointUrl 'https://my-resource.services.ai.azure.com'
            $result | Should -Be ''
        }

        It 'should return the URL for APIM gateway endpoint (azure-api.net)' {
            $apimUrl = 'https://apim-rhyv62upwtqia.azure-api.net/models-foundry/openai'
            $result = Get-GatewayUrl -EndpointUrl $apimUrl
            $result | Should -Be $apimUrl
        }

        It 'should return the URL for custom domain gateway' {
            $customUrl = 'https://ai-gateway.contoso.com'
            $result = Get-GatewayUrl -EndpointUrl $customUrl
            $result | Should -Be $customUrl
        }

        It 'should return blank for null endpoint' {
            $result = Get-GatewayUrl -EndpointUrl $null
            $result | Should -Be ''
        }

        It 'should return blank for empty endpoint' {
            $result = Get-GatewayUrl -EndpointUrl ''
            $result | Should -Be ''
        }

        It 'should be case-insensitive for standard patterns' {
            $result = Get-GatewayUrl -EndpointUrl 'HTTPS://MY-OPENAI.OPENAI.AZURE.COM'
            $result | Should -Be ''
        }

        It 'should return the URL for endpoint with path that resembles Azure domain' {
            # APIM can have paths like /openai — still a gateway
            $apimUrl = 'https://my-gateway.azure-api.net/openai/deployments/gpt-4'
            $result = Get-GatewayUrl -EndpointUrl $apimUrl
            $result | Should -Be $apimUrl
        }
    }
}
