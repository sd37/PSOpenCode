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
        Token       = [string]$tokenResult.token
        ApiBase     = ([string]$apiBase).TrimEnd('/')
        ExpiresAt   = Get-PropertyValue -Object $tokenResult -Name 'expires_at'
        GitHubHost  = $GitHubHost
        GitHubToken = $GitHubToken
    }
}

function Get-CopilotTokenExpiration {
    param([object] $ExpiresAt)

    $seconds = 0L
    if ([long]::TryParse([string]$ExpiresAt, [ref]$seconds) -and $seconds -gt 0) {
        return [DateTimeOffset]::FromUnixTimeSeconds($seconds)
    }
    $expiration = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string]$ExpiresAt, [ref]$expiration)) {
        return $expiration
    }
    return [DateTimeOffset]::MinValue
}

function Test-CopilotTokenNeedsRefresh {
    param([pscustomobject] $Connection)

    $expiration = Get-CopilotTokenExpiration -ExpiresAt $Connection.ExpiresAt
    return $expiration -ne [DateTimeOffset]::MinValue -and
        $expiration -le [DateTimeOffset]::UtcNow.AddMinutes(2)
}

function Update-CopilotConnection {
    param([pscustomobject] $Connection)

    if (-not $Connection.GitHubHost -or -not $Connection.GitHubToken) {
        throw 'The Copilot connection does not contain credentials for token refresh.'
    }
    $updated = Connect-CopilotApi -GitHubHost $Connection.GitHubHost `
        -GitHubToken $Connection.GitHubToken
    $Connection.Token = $updated.Token
    $Connection.ApiBase = $updated.ApiBase
    $Connection.ExpiresAt = $updated.ExpiresAt
}

function Test-CopilotTokenExpiredException {
    param([System.Exception] $Exception)

    $current = $Exception
    while ($current) {
        if ($current.Data['CopilotTokenExpired']) {
            return $true
        }
        $current = $current.InnerException
    }
    return $false
}

function Get-CopilotModels {
    param([pscustomobject] $Connection)

    $result = Invoke-JsonRequest -Method Get -Uri "$($Connection.ApiBase)/models" `
        -Headers (Get-CopilotHeaders -Token $Connection.Token) `
        -Operation 'Listing Copilot models'
    $endpoints = @{}
    foreach ($model in $result.data) {
        $endpoints[$model.id] = @(Get-PropertyValue -Object $model `
            -Name 'supported_endpoints' -Default @('/chat/completions'))
    }
    $Connection | Add-Member -NotePropertyName ModelEndpoints -NotePropertyValue $endpoints -Force
    return @($result.data)
}

function Get-CopilotModelEndpoint {
    param(
        [pscustomobject] $Connection,
        [string] $Model
    )

    $endpoints = Get-PropertyValue -Object $Connection -Name 'ModelEndpoints'
    if ($Model -eq 'auto' -or -not $endpoints -or -not $endpoints.ContainsKey($Model)) {
        return '/chat/completions'
    }
    if ('/chat/completions' -in $endpoints[$Model]) {
        return '/chat/completions'
    }
    if ('/responses' -in $endpoints[$Model]) {
        return '/responses'
    }
    throw "Model '$Model' does not advertise a supported HTTP inference endpoint."
}

function Get-ModelReasoningModes {
    param(
        [object[]] $Models,
        [string] $ModelId
    )

    $model = $Models | Where-Object { $_.id -eq $ModelId } | Select-Object -First 1
    if (-not $model) {
        return @()
    }
    $supports = Get-PropertyValue -Object $model.capabilities -Name 'supports'
    return @(
        Get-PropertyValue -Object $supports -Name 'reasoning_effort' -Default @() |
            ForEach-Object { [string]$_ }
    )
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
            Name = 'Reasoning'
            Expression = {
                $modes = @(Get-ModelReasoningModes -Models $Models -ModelId $_.id)
                if ($modes.Count) { $modes -join ',' } else { '-' }
            }
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
        Format-Table -AutoSize -Wrap
}
