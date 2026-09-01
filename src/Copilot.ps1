function Get-GitHubApiBaseUri {
    param([string] $GitHubHost)

    if ($GitHubHost -eq 'github.com') {
        return 'https://api.github.com'
    }
    if ($GitHubHost.EndsWith('.ghe.com', [StringComparison]::OrdinalIgnoreCase)) {
        return "https://api.$GitHubHost"
    }
    return "https://$GitHubHost/api/v3"
}

function Get-GitHubHeaders {
    param([string] $Token)

    return @{
        Authorization                  = "token $Token"
        Accept                         = 'application/json'
        'editor-version'               = 'vscode/1.100.0'
        'editor-plugin-version'        = "copilot-chat/$($script:CopilotVersion)"
        'user-agent'                   = "GitHubCopilotChat/$($script:CopilotVersion)"
        'x-github-api-version'         = $script:ApiVersion
        'x-vscode-user-agent-library-version' = 'electron-fetch'
    }
}

function Get-CopilotHeaders {
    param([string] $Token)

    return @{
        Authorization                  = "Bearer $Token"
        Accept                         = 'application/json'
        'copilot-integration-id'       = 'vscode-chat'
        'editor-version'               = 'vscode/1.100.0'
        'editor-plugin-version'        = "copilot-chat/$($script:CopilotVersion)"
        'user-agent'                   = "GitHubCopilotChat/$($script:CopilotVersion)"
        'openai-intent'                = 'conversation-panel'
        'x-github-api-version'         = $script:ApiVersion
        'x-request-id'                 = [guid]::NewGuid().ToString()
        'x-vscode-user-agent-library-version' = 'electron-fetch'
    }
}

function Connect-CopilotApi {
    param(
        [string] $GitHubHost,
        [string] $GitHubToken
    )

    $githubApi = Get-GitHubApiBaseUri -GitHubHost $GitHubHost
    $tokenResult = Invoke-JsonRequest -Method Get `
        -Uri "$githubApi/copilot_internal/v2/token" `
        -Headers (Get-GitHubHeaders -Token $GitHubToken) `
        -Operation 'Exchanging the GitHub token for a Copilot token'

    $apiBase = $null
    $endpoints = Get-PropertyValue -Object $tokenResult -Name 'endpoints'
    if ($endpoints) {
        $apiBase = Get-PropertyValue -Object $endpoints -Name 'api'
    }
    if (-not $apiBase) {
        $apiBase = if ($GitHubHost -eq 'github.com') {
            'https://api.githubcopilot.com'
        }
        else {
            'https://api.enterprise.githubcopilot.com'
        }
    }

    return [pscustomobject]@{
        Token     = [string]$tokenResult.token
        ApiBase   = ([string]$apiBase).TrimEnd('/')
        ExpiresAt = Get-PropertyValue -Object $tokenResult -Name 'expires_at'
    }
}

function Get-CopilotModels {
    param([pscustomobject] $Connection)

    $result = Invoke-JsonRequest -Method Get -Uri "$($Connection.ApiBase)/models" `
        -Headers (Get-CopilotHeaders -Token $Connection.Token) `
        -Operation 'Listing Copilot models'
    return @($result.data)
}

function Show-CopilotModels {
    param([object[]] $Models)

    $Models |
        Where-Object {
            $policy = Get-PropertyValue -Object $_ -Name 'policy'
            (Get-PropertyValue -Object $_ -Name 'model_picker_enabled' -Default $true) -and
            (Get-PropertyValue -Object $policy -Name 'state' -Default 'enabled') -eq 'enabled'
        } |
        Sort-Object vendor, name |
        Select-Object @{
            Name = 'Id'
            Expression = { $_.id }
        }, @{
            Name = 'Vendor'
            Expression = { Get-PropertyValue -Object $_ -Name 'vendor' -Default '-' }
        }, @{
            Name = 'Name'
            Expression = { $_.name }
        }, @{
            Name = 'Context'
            Expression = {
                $limits = Get-PropertyValue -Object $_.capabilities -Name 'limits'
                Get-PropertyValue -Object $limits -Name 'max_context_window_tokens' -Default '-'
            }
        }, @{
            Name = 'Tools'
            Expression = {
                $supports = Get-PropertyValue -Object $_.capabilities -Name 'supports'
                Get-PropertyValue -Object $supports -Name 'tool_calls' -Default $false
            }
        } |
        Format-Table -AutoSize
}
