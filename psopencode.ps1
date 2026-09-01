#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments)]
    [string[]] $Prompt,

    [Alias('m')]
    [string] $Model = 'auto',

    [Alias('C')]
    [string] $WorkingDirectory = (Get-Location).Path,

    [string] $HostName = 'microsoft.ghe.com',

    [switch] $Login,

    [switch] $Logout,

    [switch] $ListModels,

    [switch] $AutoApprove,

    [switch] $NoTools,

    [ValidateSet('build', 'plan')]
    [string] $Mode = 'build',

    [ValidateSet('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max')]
    [string] $ReasoningEffort,

    [ValidateRange(1, 100)]
    [int] $MaxAgentSteps = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ApiVersion = '2025-04-01'
$script:CopilotVersion = '0.26.7'
$script:OAuthClientId = 'Iv1.b507a08c87ecfe98'

function Get-PropertyValue {
    param(
        [object] $Object,
        [string] $Name,
        [object] $Default = $null
    )

    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) {
        return $Object.$Name
    }
    return $Default
}

function Get-AuthPath {
    param([string] $GitHubHost)

    $safeHost = $GitHubHost -replace '[^a-zA-Z0-9.-]', '_'
    return Join-Path (Join-Path $HOME '.psopencode') "auth-$safeHost.json"
}

function Save-GitHubToken {
    param(
        [string] $GitHubHost,
        [string] $Token
    )

    if (-not $IsWindows) {
        throw @'
Secure token persistence currently requires Windows DPAPI. On non-Windows,
set PSOPENCODE_GITHUB_TOKEN for the current process instead.
'@
    }

    $path = Get-AuthPath -GitHubHost $GitHubHost
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    $secureToken = ConvertTo-SecureString -String $Token -AsPlainText -Force
    $document = [ordered]@{
        host           = $GitHubHost
        protectedToken = ConvertFrom-SecureString -SecureString $secureToken
    }
    [System.IO.File]::WriteAllText(
        $path,
        ($document | ConvertTo-Json),
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Get-GitHubToken {
    param([string] $GitHubHost)

    if ($env:PSOPENCODE_GITHUB_TOKEN) {
        return $env:PSOPENCODE_GITHUB_TOKEN
    }

    $path = Get-AuthPath -GitHubHost $GitHubHost
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    if (-not $IsWindows) {
        throw 'Stored credentials require Windows DPAPI. Set PSOPENCODE_GITHUB_TOKEN instead.'
    }

    $document = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
    $secureToken = ConvertTo-SecureString -String $document.protectedToken
    return [System.Net.NetworkCredential]::new('', $secureToken).Password
}

function Remove-GitHubToken {
    param([string] $GitHubHost)

    $path = Get-AuthPath -GitHubHost $GitHubHost
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Invoke-JsonRequest {
    param(
        [ValidateSet('Get', 'Post')]
        [string] $Method,
        [string] $Uri,
        [hashtable] $Headers = @{},
        [object] $Body,
        [string] $Operation = 'Request',
        [string] $ContentType = 'application/json'
    )

    $client = [System.Net.Http.HttpClient]::new()
    $request = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::$Method,
        $Uri
    )
    try {
        foreach ($entry in $Headers.GetEnumerator()) {
            if (-not $request.Headers.TryAddWithoutValidation(
                [string]$entry.Key,
                [string]$entry.Value
            )) {
                throw "Invalid HTTP header: $($entry.Key)"
            }
        }

        if ($PSBoundParameters.ContainsKey('Body')) {
            $text = if ($ContentType -eq 'application/json') {
                $Body | ConvertTo-Json -Compress -Depth 100
            }
            elseif ($ContentType -eq 'application/x-www-form-urlencoded') {
                ($Body.GetEnumerator() | ForEach-Object {
                    '{0}={1}' -f
                        [System.Net.WebUtility]::UrlEncode([string]$_.Key),
                        [System.Net.WebUtility]::UrlEncode([string]$_.Value)
                }) -join '&'
            }
            else {
                [string]$Body
            }
            $request.Content = [System.Net.Http.StringContent]::new(
                $text,
                [System.Text.UTF8Encoding]::new($false),
                $ContentType
            )
        }

        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        try {
            $responseBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if (-not $response.IsSuccessStatusCode) {
                throw "$Operation failed with HTTP $([int]$response.StatusCode)`: $responseBody"
            }
            if (-not $responseBody) {
                return $null
            }
            return $responseBody | ConvertFrom-Json -Depth 100
        }
        finally {
            $response.Dispose()
        }
    }
    finally {
        $request.Dispose()
        $client.Dispose()
    }
}

function Connect-GitHubDevice {
    param([string] $GitHubHost)

    $baseUri = "https://$GitHubHost"
    $device = Invoke-JsonRequest -Method Post -Uri "$baseUri/login/device/code" `
        -Headers @{ Accept = 'application/json' } `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{
            client_id = $script:OAuthClientId
            scope     = 'read:user'
        } `
        -Operation "Starting device login at $GitHubHost"

    Write-Host ''
    Write-Host 'Sign in with your Microsoft credentials:' -ForegroundColor Cyan
    Write-Host $device.verification_uri
    Write-Host "Code: $($device.user_code)" -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Waiting for authorization...' -ForegroundColor DarkGray

    $interval = [Math]::Max([int]$device.interval, 5)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds([int]$device.expires_in)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds $interval
        $tokenResult = Invoke-JsonRequest -Method Post `
            -Uri "$baseUri/login/oauth/access_token" `
            -Headers @{ Accept = 'application/json' } `
            -ContentType 'application/x-www-form-urlencoded' `
            -Body @{
                client_id   = $script:OAuthClientId
                device_code = $device.device_code
                grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
            } `
            -Operation "Polling device login at $GitHubHost"

        $accessToken = Get-PropertyValue -Object $tokenResult -Name 'access_token'
        if ($accessToken) {
            Save-GitHubToken -GitHubHost $GitHubHost -Token $accessToken
            return $accessToken
        }

        $deviceError = Get-PropertyValue -Object $tokenResult -Name 'error'
        switch ($deviceError) {
            'authorization_pending' {
                continue
            }
            'slow_down' {
                $interval += 5
                continue
            }
            'access_denied' {
                throw 'Login was denied.'
            }
            'expired_token' {
                throw 'The device code expired. Run -Login again.'
            }
            default {
                $description = Get-PropertyValue -Object $tokenResult -Name 'error_description'
                throw "Device login failed: $($description ?? $deviceError)"
            }
        }
    }

    throw 'The device code expired. Run -Login again.'
}

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

function Get-ToolDefinitions {
    param(
        [ValidateSet('build', 'plan')]
        [string] $Mode
    )

    $tools = @(
        @{
            type = 'function'
            function = @{
                name        = 'list_files'
                description = 'List files under the workspace. Paths are relative to the workspace.'
                parameters  = @{
                    type       = 'object'
                    properties = @{
                        path    = @{ type = 'string'; description = 'Directory, default "."' }
                        pattern = @{ type = 'string'; description = 'PowerShell wildcard, default "*"' }
                        recurse = @{ type = 'boolean'; description = 'Whether to recurse' }
                    }
                }
            }
        },
        @{
            type = 'function'
            function = @{
                name        = 'read_file'
                description = 'Read a UTF-8 text file in the workspace.'
                parameters  = @{
                    type       = 'object'
                    required   = @('path')
                    properties = @{
                        path       = @{ type = 'string' }
                        start_line = @{ type = 'integer'; minimum = 1 }
                        line_count = @{ type = 'integer'; minimum = 1; maximum = 2000 }
                    }
                }
            }
        },
        @{
            type = 'function'
            function = @{
                name        = 'search_text'
                description = 'Search text files in the workspace using a .NET regular expression.'
                parameters  = @{
                    type       = 'object'
                    required   = @('pattern')
                    properties = @{
                        pattern   = @{ type = 'string' }
                        path      = @{ type = 'string'; description = 'Directory, default "."' }
                        file_glob = @{ type = 'string'; description = 'PowerShell wildcard, default "*"' }
                    }
                }
            }
        },
        @{
            type = 'function'
            function = @{
                name        = 'write_file'
                description = 'Create or overwrite a UTF-8 text file in the workspace.'
                parameters  = @{
                    type       = 'object'
                    required   = @('path', 'content')
                    properties = @{
                        path    = @{ type = 'string' }
                        content = @{ type = 'string' }
                    }
                }
            }
        },
        @{
            type = 'function'
            function = @{
                name        = 'replace_text'
                description = 'Replace one exact, unique text occurrence in a workspace file.'
                parameters  = @{
                    type       = 'object'
                    required   = @('path', 'old_text', 'new_text')
                    properties = @{
                        path     = @{ type = 'string' }
                        old_text = @{ type = 'string' }
                        new_text = @{ type = 'string' }
                    }
                }
            }
        },
        @{
            type = 'function'
            function = @{
                name        = 'run_powershell'
                description = 'Run a PowerShell command in the workspace.'
                parameters  = @{
                    type       = 'object'
                    required   = @('command')
                    properties = @{
                        command = @{ type = 'string' }
                    }
                }
            }
        }
    )

    if ($Mode -eq 'plan') {
        return @($tools | Where-Object {
            $_.function.name -in @('list_files', 'read_file', 'search_text', 'run_powershell')
        })
    }
    return $tools
}

function Resolve-WorkspacePath {
    param(
        [string] $Root,
        [string] $Path,
        [switch] $MustExist
    )

    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) {
        [System.IO.Path]::GetFullPath($Path)
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path $Root $Path))
    }

    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $prefix = "$rootPath$([System.IO.Path]::DirectorySeparatorChar)"
    if ($candidate -ne $rootPath -and
        -not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the workspace: $Path"
    }
    if ($MustExist -and -not (Test-Path -LiteralPath $candidate)) {
        throw "Path does not exist: $Path"
    }

    if (Test-Path -LiteralPath $candidate) {
        $resolved = (Resolve-Path -LiteralPath $candidate).Path
        if ($resolved -ne $rootPath -and
            -not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Resolved path is outside the workspace: $Path"
        }
        return $resolved
    }
    return $candidate
}

function Confirm-ToolCall {
    param(
        [string] $Name,
        [object] $Arguments,
        [bool] $ApproveAutomatically,
        [ValidateSet('build', 'plan')]
        [string] $Mode
    )

    if ($Mode -eq 'plan' -and $Name -in @('write_file', 'replace_text')) {
        return $false
    }
    if ($Name -in @('list_files', 'read_file', 'search_text')) {
        return $true
    }
    if ($Mode -eq 'build' -and $ApproveAutomatically) {
        return $true
    }
    if ([Console]::IsInputRedirected) {
        return $false
    }

    Write-Host ''
    Write-Host "Permission requested: $Name" -ForegroundColor Yellow
    Write-Host ($Arguments | ConvertTo-Json -Depth 20)
    return (Read-Host 'Allow once? [y/N]') -match '^(y|yes)$'
}

function Invoke-AgentTool {
    param(
        [string] $Name,
        [object] $Arguments,
        [string] $Root,
        [ValidateSet('build', 'plan')]
        [string] $Mode
    )

    if ($Mode -eq 'plan' -and $Name -in @('write_file', 'replace_text')) {
        throw "Tool '$Name' is unavailable in plan mode."
    }

    switch ($Name) {
        'list_files' {
            $path = Resolve-WorkspacePath -Root $Root `
                -Path (Get-PropertyValue -Object $Arguments -Name 'path' -Default '.') `
                -MustExist
            $pattern = Get-PropertyValue -Object $Arguments -Name 'pattern' -Default '*'
            $recurse = [bool](Get-PropertyValue -Object $Arguments -Name 'recurse' -Default $false)
            $items = Get-ChildItem -LiteralPath $path -Filter $pattern -File -Recurse:$recurse |
                Select-Object -First 1000
            return (($items | ForEach-Object {
                [System.IO.Path]::GetRelativePath($Root, $_.FullName)
            }) -join "`n")
        }
        'read_file' {
            $path = Resolve-WorkspacePath -Root $Root -Path $Arguments.path -MustExist
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Not a file: $($Arguments.path)"
            }
            $lines = [System.IO.File]::ReadAllLines($path)
            $start = [Math]::Max(
                [int](Get-PropertyValue -Object $Arguments -Name 'start_line' -Default 1),
                1
            )
            $count = [Math]::Min(
                [int](Get-PropertyValue -Object $Arguments -Name 'line_count' -Default 400),
                2000
            )
            $end = [Math]::Min($start - 1 + $count, $lines.Length)
            if ($start -gt $lines.Length) {
                return ''
            }
            return (($start - 1)..($end - 1) | ForEach-Object {
                "$($_ + 1). $($lines[$_])"
            }) -join "`n"
        }
        'search_text' {
            $path = Resolve-WorkspacePath -Root $Root `
                -Path (Get-PropertyValue -Object $Arguments -Name 'path' -Default '.') `
                -MustExist
            $glob = Get-PropertyValue -Object $Arguments -Name 'file_glob' -Default '*'
            $regex = [regex]::new([string]$Arguments.pattern)
            $matches = [System.Collections.Generic.List[string]]::new()
            foreach ($file in (Get-ChildItem -LiteralPath $path -Filter $glob -File -Recurse)) {
                if ($file.Length -gt 1MB) {
                    continue
                }
                $lineNumber = 0
                foreach ($line in [System.IO.File]::ReadLines($file.FullName)) {
                    $lineNumber++
                    if ($regex.IsMatch($line)) {
                        $relative = [System.IO.Path]::GetRelativePath($Root, $file.FullName)
                        $matches.Add("$relative`:$lineNumber`:$line")
                        if ($matches.Count -ge 500) {
                            return $matches -join "`n"
                        }
                    }
                }
            }
            return $matches -join "`n"
        }
        'write_file' {
            $path = Resolve-WorkspacePath -Root $Root -Path $Arguments.path
            [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $path))
            [System.IO.File]::WriteAllText(
                $path,
                [string]$Arguments.content,
                [System.Text.UTF8Encoding]::new($false)
            )
            return "Wrote $([System.IO.Path]::GetRelativePath($Root, $path))."
        }
        'replace_text' {
            $path = Resolve-WorkspacePath -Root $Root -Path $Arguments.path -MustExist
            $content = [System.IO.File]::ReadAllText($path)
            $oldText = [string]$Arguments.old_text
            $first = $content.IndexOf($oldText, [StringComparison]::Ordinal)
            if ($first -lt 0) {
                throw 'old_text was not found.'
            }
            if ($content.IndexOf($oldText, $first + $oldText.Length, [StringComparison]::Ordinal) -ge 0) {
                throw 'old_text is not unique; provide more surrounding text.'
            }
            $updated = $content.Substring(0, $first) + [string]$Arguments.new_text +
                $content.Substring($first + $oldText.Length)
            [System.IO.File]::WriteAllText(
                $path,
                $updated,
                [System.Text.UTF8Encoding]::new($false)
            )
            return "Updated $([System.IO.Path]::GetRelativePath($Root, $path))."
        }
        'run_powershell' {
            $previousLocation = Get-Location
            try {
                Set-Location -LiteralPath $Root
                $scriptBlock = [scriptblock]::Create([string]$Arguments.command)
                $output = & $scriptBlock 2>&1 | Out-String
                return $output.TrimEnd()
            }
            finally {
                Set-Location -LiteralPath $previousLocation
            }
        }
        default {
            throw "Unknown tool: $Name"
        }
    }
}

function Invoke-CopilotChat {
    param(
        [pscustomobject] $Connection,
        [string] $SelectedModel,
        [System.Collections.Generic.List[object]] $Messages,
        [bool] $DisableTools,
        [ValidateSet('build', 'plan')]
        [string] $Mode,
        [string] $Effort
    )

    $body = [ordered]@{
        model    = $SelectedModel
        messages = @($Messages)
        stream   = $false
    }
    if (-not $DisableTools) {
        $body.tools = @(Get-ToolDefinitions -Mode $Mode)
        $body.tool_choice = 'auto'
    }
    if ($Effort) {
        $body.reasoning_effort = $Effort
    }

    $headers = Get-CopilotHeaders -Token $Connection.Token
    $headers['x-initiator'] = if ($Messages.Count -gt 2) { 'agent' } else { 'user' }
    return Invoke-JsonRequest -Method Post `
        -Uri "$($Connection.ApiBase)/chat/completions" `
        -Headers $headers `
        -Body $body `
        -Operation "Calling Copilot model '$SelectedModel'"
}

function Invoke-AgentTurn {
    param(
        [pscustomobject] $Connection,
        [string] $SelectedModel,
        [System.Collections.Generic.List[object]] $Messages,
        [string] $Text,
        [string] $Root,
        [bool] $ApproveAutomatically,
        [bool] $DisableTools,
        [ValidateSet('build', 'plan')]
        [string] $Mode,
        [string] $Effort,
        [int] $StepLimit
    )

    $Messages.Add(@{ role = 'user'; content = $Text })

    for ($step = 1; $step -le $StepLimit; $step++) {
        $response = Invoke-CopilotChat -Connection $Connection `
            -SelectedModel $SelectedModel -Messages $Messages `
            -DisableTools $DisableTools -Mode $Mode -Effort $Effort
        $message = $response.choices[0].message
        $content = [string](Get-PropertyValue -Object $message -Name 'content' -Default '')
        $toolCalls = @(Get-PropertyValue -Object $message -Name 'tool_calls' -Default @())

        $assistantMessage = [ordered]@{
            role    = 'assistant'
            content = if ($content) { $content } else { $null }
        }
        if ($toolCalls.Count -gt 0) {
            $assistantMessage.tool_calls = $toolCalls
        }
        $Messages.Add($assistantMessage)

        if ($content) {
            Write-Host $content
        }
        if ($toolCalls.Count -eq 0) {
            return
        }

        foreach ($toolCall in $toolCalls) {
            $name = [string]$toolCall.function.name
            try {
                $arguments = if ($toolCall.function.arguments) {
                    $toolCall.function.arguments | ConvertFrom-Json -Depth 100
                }
                else {
                    [pscustomobject]@{}
                }
                Write-Host ">> tool: $name" -ForegroundColor DarkGray
                if (-not (Confirm-ToolCall -Name $name -Arguments $arguments `
                    -ApproveAutomatically $ApproveAutomatically -Mode $Mode)) {
                    $result = 'Permission denied by the user.'
                }
                else {
                    $result = Invoke-AgentTool -Name $name -Arguments $arguments `
                        -Root $Root -Mode $Mode
                    if (-not $result) {
                        $result = 'Completed successfully with no output.'
                    }
                }
            }
            catch {
                $result = "Tool failed: $($_.Exception.Message)"
                Write-Host $result -ForegroundColor Red
            }

            $Messages.Add(@{
                role         = 'tool'
                tool_call_id = [string]$toolCall.id
                content      = [string]$result
            })
        }
    }

    throw "Agent exceeded the maximum of $StepLimit model steps."
}

function Get-ModeInstructions {
    param(
        [ValidateSet('build', 'plan')]
        [string] $Mode
    )

    if ($Mode -eq 'plan') {
        return @'
CURRENT MODE: PLAN. This supersedes any earlier mode instructions. Explore and
analyze the workspace, ask clarifying questions when needed, and produce an
actionable implementation plan. Do not modify files. File mutation tools are
unavailable. Use PowerShell only for read-only inspection and only after the
user approves the command.
'@
    }

    return @'
CURRENT MODE: BUILD. This supersedes any earlier mode instructions. Inspect,
modify, and validate the workspace as needed to complete the user's request.
Use tools rather than merely describing changes.
'@
}

function New-MessageHistory {
    param(
        [string] $Root,
        [ValidateSet('build', 'plan')]
        [string] $Mode
    )

    $messages = [System.Collections.Generic.List[object]]::new()
    $modeInstructions = Get-ModeInstructions -Mode $Mode
    $messages.Add(@{
        role    = 'system'
        content = @"
You are a concise coding agent working in this Windows workspace:
$Root

Keep paths inside the workspace. Never claim an action succeeded without using
a tool and checking its result.

$modeInstructions
"@
    })
    return ,$messages
}

$HostName = $HostName.Trim().ToLowerInvariant()
if ($HostName -notmatch '^[a-z0-9.-]+$') {
    throw "Invalid GitHub host name: $HostName"
}

if ($Logout) {
    Remove-GitHubToken -GitHubHost $HostName
    Write-Host "Logged out from $HostName."
    return
}

$didLogin = $false
if ($Login) {
    Remove-GitHubToken -GitHubHost $HostName
    $githubToken = Connect-GitHubDevice -GitHubHost $HostName
    $didLogin = $true
}
else {
    $githubToken = Get-GitHubToken -GitHubHost $HostName
    if (-not $githubToken) {
        $githubToken = Connect-GitHubDevice -GitHubHost $HostName
        $didLogin = $true
    }
}

$connection = Connect-CopilotApi -GitHubHost $HostName -GitHubToken $githubToken
$models = Get-CopilotModels -Connection $connection

if ($didLogin -and -not $ListModels) {
    Write-Host "Logged in to $HostName. Available Copilot models:" -ForegroundColor Green
    Show-CopilotModels -Models $models
}

if ($ListModels) {
    Show-CopilotModels -Models $models
    return
}

$availableModelIds = @($models | Where-Object {
    $policy = Get-PropertyValue -Object $_ -Name 'policy'
    (Get-PropertyValue -Object $policy -Name 'state' -Default 'enabled') -eq 'enabled'
} | ForEach-Object { $_.id })
if ($Model -ne 'auto' -and $Model -notin $availableModelIds) {
    throw "Model '$Model' is not available. Run with -ListModels to see available model IDs."
}

$root = (Resolve-Path -LiteralPath $WorkingDirectory).Path
$messages = New-MessageHistory -Root $root -Mode $Mode
$singlePrompt = ($Prompt -join ' ').Trim()

if ($singlePrompt) {
    Invoke-AgentTurn -Connection $connection -SelectedModel $Model -Messages $messages `
        -Text $singlePrompt -Root $root -ApproveAutomatically ([bool]$AutoApprove) `
        -DisableTools ([bool]$NoTools) -Mode $Mode -Effort $ReasoningEffort `
        -StepLimit $MaxAgentSteps
    return
}

Write-Host "PSOpenCode | $HostName | model: $Model | mode: $Mode | cwd: $root" `
    -ForegroundColor Cyan
Write-Host 'Commands: /help, /mode [build|plan], /models, /model <id>, /new, /exit'

while ($true) {
    $inputText = Read-Host "`nYou [$Mode]"
    if (-not $inputText.Trim()) {
        continue
    }

    if ($inputText -in @('/exit', '/quit')) {
        break
    }
    if ($inputText -eq '/help') {
        Write-Host '/mode          Toggle between build and plan mode'
        Write-Host '/mode <mode>   Switch to build or plan mode'
        Write-Host '/models       List models available to your account'
        Write-Host '/model <id>   Start a new conversation with another model'
        Write-Host '/new          Start a fresh conversation'
        Write-Host '/exit         Exit'
        continue
    }
    if ($inputText -eq '/models') {
        Show-CopilotModels -Models $models
        continue
    }
    if ($inputText -eq '/new') {
        $messages = New-MessageHistory -Root $root -Mode $Mode
        Write-Host 'Started a new conversation.' -ForegroundColor DarkGray
        continue
    }
    if ($inputText -eq '/mode' -or $inputText -match '^/mode\s+(build|plan)$') {
        $nextMode = if ($inputText -eq '/mode') {
            if ($Mode -eq 'build') { 'plan' } else { 'build' }
        }
        else {
            $Matches[1].ToLowerInvariant()
        }
        if ($nextMode -ne $Mode) {
            $Mode = $nextMode
            $messages.Add(@{
                role    = 'system'
                content = Get-ModeInstructions -Mode $Mode
            })
        }
        Write-Host "Switched to $Mode mode." -ForegroundColor Cyan
        continue
    }
    if ($inputText -match '^/mode\b') {
        Write-Host 'Mode must be build or plan.' -ForegroundColor Red
        continue
    }
    if ($inputText -match '^/model\s+(.+)$') {
        $nextModel = $Matches[1].Trim()
        if ($nextModel -ne 'auto' -and $nextModel -notin $availableModelIds) {
            Write-Host "Unknown model '$nextModel'. Use /models to list available IDs." `
                -ForegroundColor Red
            continue
        }
        $Model = $nextModel
        $messages = New-MessageHistory -Root $root -Mode $Mode
        Write-Host "Started a new conversation with $Model." -ForegroundColor DarkGray
        continue
    }

    Write-Host ''
    Write-Host 'Assistant:' -ForegroundColor Green
    Invoke-AgentTurn -Connection $connection -SelectedModel $Model -Messages $messages `
        -Text $inputText -Root $root -ApproveAutomatically ([bool]$AutoApprove) `
        -DisableTools ([bool]$NoTools) -Mode $Mode -Effort $ReasoningEffort `
        -StepLimit $MaxAgentSteps
}
