#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments)]
    [string[]] $Prompt,

    [Alias('f')]
    [string] $PromptFile,

    [Alias('m')]
    [string] $Model = 'claude-opus-4.8',

    [Alias('C')]
    [string] $WorkingDirectory = (Get-Location).Path,

    [switch] $AllowOutsideWorkspace,

    [string] $HostName = 'microsoft.ghe.com',

    [switch] $Login,

    [switch] $Logout,

    [switch] $ListModels,

    [switch] $AutoApprove,

    [switch] $NoTools,

    [switch] $NoSessionHistory,

    [string[]] $Mcp = @(),

    [string] $McpConfig,

    [ValidateSet('build', 'plan')]
    [string] $Mode = 'build',

    [ValidateSet('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max')]
    [string] $ReasoningEffort = 'max',

    [ValidateRange(1, 100)]
    [int] $MaxAgentSteps = 20
)

if ([string]$ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    throw @"
PSOpenCode requires PowerShell FullLanguage mode, but this host is running in
$($ExecutionContext.SessionState.LanguageMode) mode. Organization policy can
restrict .NET networking, streaming, cryptography, and secure credential APIs
that PSOpenCode requires. Use an organization-approved PowerShell host where
PSOpenCode is trusted to run in FullLanguage mode, or ask your administrator to
approve the PSOpenCode scripts. PSOpenCode will not bypass the policy.
"@
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$reasoningEffortWasSpecified = $PSBoundParameters.ContainsKey('ReasoningEffort')

$script:ApiVersion = '2025-04-01'
$script:CopilotVersion = '0.26.7'
$script:OAuthClientId = 'Iv1.b507a08c87ecfe98'

$sourceFiles = @(
    'src\Common.ps1'
    'src\Auth.ps1'
    'src\McpAuth.ps1'
    'src\McpTransport.ps1'
    'src\Mcp.ps1'
    'src\Tools.ps1'
    'src\Copilot.ps1'
    'src\Streaming.ps1'
    'src\Agent.ps1'
    'src\Session.ps1'
)
foreach ($sourceFile in $sourceFiles) {
    $sourcePath = Join-Path $PSScriptRoot $sourceFile
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Required source file is missing: $sourcePath"
    }
    . $sourcePath
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

$promptFileText = ''
if ($PromptFile) {
    $resolvedPromptFile = Resolve-Path -LiteralPath $PromptFile -ErrorAction SilentlyContinue
    if (-not $resolvedPromptFile -or
        -not (Test-Path -LiteralPath $resolvedPromptFile.Path -PathType Leaf)) {
        throw "Prompt file not found: $PromptFile"
    }
    $promptFileText = [System.IO.File]::ReadAllText($resolvedPromptFile.Path)
    if (-not $promptFileText.Trim()) {
        throw "Prompt file is empty: $PromptFile"
    }
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
if ($Model -ne 'auto' -and $reasoningEffortWasSpecified) {
    $supportedReasoning = @(Get-ModelReasoningModes -Models $models -ModelId $Model)
    if ($ReasoningEffort -notin $supportedReasoning) {
        $available = if ($supportedReasoning.Count) {
            $supportedReasoning -join ', '
        }
        else {
            'none'
        }
        throw "Model '$Model' does not support reasoning '$ReasoningEffort'. " +
            "Available reasoning modes: $available."
    }
}
$effectiveReasoningEffort = Get-EffectiveReasoningEffort -SelectedModel $Model `
    -RequestedEffort $ReasoningEffort -WasSpecified $reasoningEffortWasSpecified
$reasoningStatus = if ($effectiveReasoningEffort) {
    $effectiveReasoningEffort
}
else {
    'model-default'
}

if (-not $McpConfig) {
    $McpConfig = Join-Path $PSScriptRoot 'mcp.json'
}
$mcpState = Import-McpConfiguration -Path $McpConfig
$requestedMcpServers = @(
    $Mcp |
        ForEach-Object { $_ -split ',' } |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
)
if (($requestedMcpServers -contains 'all' -or
    $requestedMcpServers -contains 'none') -and
    $requestedMcpServers.Count -ne 1) {
    throw "MCP selections 'all' and 'none' must be used by themselves."
}
if ($requestedMcpServers -contains 'all') {
    $requestedMcpServers = @($mcpState.Servers.Keys)
}
elseif ($requestedMcpServers -contains 'none') {
    $requestedMcpServers = @()
}

$root = (Resolve-Path -LiteralPath $WorkingDirectory).Path
$messages = New-MessageHistory -Root $root -Mode $Mode
$promptSegments = @($promptFileText, ($Prompt -join ' ')) |
    Where-Object { $_ -and $_.Trim() }
$singlePrompt = ($promptSegments -join "`n`n").Trim()

try {
    foreach ($serverName in $requestedMcpServers) {
        if (-not $mcpState.Servers.ContainsKey($serverName)) {
            $configured = @($mcpState.Servers.Keys | Sort-Object) -join ', '
            throw "Unknown MCP server '$serverName'. Configured servers: $configured."
        }
        Enable-McpServer -State $mcpState -Name $serverName
        Write-Host "Connected MCP server '$serverName'." -ForegroundColor DarkGray
    }
    $mcpStatus = Get-McpSelectionLabel -State $mcpState

    if ($singlePrompt) {
        Invoke-AgentTurn -Connection $connection -SelectedModel $Model -Messages $messages `
            -Text $singlePrompt -Root $root -ApproveAutomatically ([bool]$AutoApprove) `
            -AllowOutsideWorkspace ([bool]$AllowOutsideWorkspace) `
            -DisableTools ([bool]$NoTools) -Mode $Mode -McpState $mcpState `
            -Effort $effectiveReasoningEffort -StepLimit $MaxAgentSteps
        return
    }

    Write-Host (
        "PSOpenCode | $HostName | model: $Model | reasoning: $reasoningStatus | " +
        "mode: $Mode | mcp: $mcpStatus | cwd: $root"
    ) -ForegroundColor Cyan
    Write-Host (
        'Commands: /help, /mode [build|plan], /models, /mcps, ' +
        '/mcp <name> [on|off], /model <id> [reasoning], /prompt <path>, ' +
        '/sessions [load <id>], /new, /exit'
    )
    Write-Host 'Status: idle' -ForegroundColor DarkGray

    $sessionId = New-SessionId

    while ($true) {
        $inputText = Read-Host (
            "`nYou [$Mode | reasoning: $reasoningStatus | mcp: $mcpStatus]"
        )
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
            Write-Host '/mcps         Show configured MCP servers and session status'
            Write-Host '/mcp <name> [on|off]  Toggle or select an MCP server for this session'
            Write-Host '/model <id> [reasoning]  Select a model and optional reasoning mode'
            Write-Host '/prompt <path>  Run a prompt read from a file (relative to the workspace)'
            Write-Host '/sessions [load <id|#>]  List saved sessions, or load one into this session'
            Write-Host '/new          Start a fresh conversation'
            Write-Host '/exit         Exit'
            continue
        }
        if ($inputText -eq '/models') {
            Show-CopilotModels -Models $models
            continue
        }
        if ($inputText -match '^/sessions?\s+load\s+(.+)$') {
            $sessionRef = $Matches[1].Trim()
            $resolvedSessionId = Resolve-SessionReference -Reference $sessionRef
            if (-not $resolvedSessionId) {
                Write-Host "No session matching '$sessionRef'. Use /sessions to list them." `
                    -ForegroundColor Red
                continue
            }
            $loadedSession = Import-Session -Id $resolvedSessionId
            if (-not $loadedSession -or $loadedSession.Messages.Count -eq 0) {
                Write-Host "Unable to load session '$resolvedSessionId'." -ForegroundColor Red
                continue
            }
            $messages = $loadedSession.Messages
            $sessionId = $loadedSession.Id
            if ($loadedSession.Mode -in @('build', 'plan')) {
                $Mode = $loadedSession.Mode
            }
            Write-Host (
                "Loaded session $($loadedSession.Id): $($messages.Count) messages, " +
                "mode $Mode."
            ) -ForegroundColor Cyan
            if ($loadedSession.Model -and $loadedSession.Model -ne $Model) {
                Write-Host (
                    "This session was saved with model $($loadedSession.Model); " +
                    "the active model is $Model. Use /model $($loadedSession.Model) to switch."
                ) -ForegroundColor DarkGray
            }
            if ($loadedSession.Root -and $loadedSession.Root -ne $root) {
                Write-Host (
                    "Note: it was created in $($loadedSession.Root); tools act on $root."
                ) -ForegroundColor DarkGray
            }
            continue
        }
        if ($inputText -in @('/session', '/sessions')) {
            Show-Sessions
            continue
        }
        if ($inputText -match '^/sessions?\b') {
            Write-Host 'Usage: /sessions  or  /sessions load <id|#>' -ForegroundColor Red
            continue
        }
        if ($inputText -in @('/mcp', '/mcps')) {
            Show-McpServers -State $mcpState
            continue
        }
        if ($inputText -match '^/mcp\s+(\S+)(?:\s+(on|off))?\s*$') {
            $serverName = $Matches[1]
            $requestedAction = if ($Matches.ContainsKey(2)) { $Matches[2] } else { '' }
            if (-not $mcpState.Servers.ContainsKey($serverName)) {
                Write-Host "Unknown MCP server '$serverName'. Use /mcps to list servers." `
                    -ForegroundColor Red
                continue
            }
            $server = $mcpState.Servers[$serverName]
            $enable = if ($requestedAction) {
                $requestedAction -eq 'on'
            }
            else {
                -not $server.Selected
            }
            try {
                if ($enable) {
                    Enable-McpServer -State $mcpState -Name $serverName
                    $messages.Add(@{
                        role = 'system'
                        content = "MCP server '$serverName' is selected for this session."
                    })
                    Write-Host "Selected MCP server '$serverName'." -ForegroundColor Cyan
                }
                else {
                    Disable-McpServer -State $mcpState -Name $serverName
                    $messages.Add(@{
                        role = 'system'
                        content = "MCP server '$serverName' is disabled for this session."
                    })
                    Write-Host "Disabled MCP server '$serverName'." -ForegroundColor Cyan
                }
            }
            catch {
                Write-Host $_.Exception.Message -ForegroundColor Red
            }
            $mcpStatus = Get-McpSelectionLabel -State $mcpState
            continue
        }
        if ($inputText -match '^/mcp\b') {
            Write-Host 'Usage: /mcp <name> [on|off]. Use /mcps to list servers.' `
                -ForegroundColor Red
            continue
        }
        if ($inputText -eq '/new') {
            $messages = New-MessageHistory -Root $root -Mode $Mode
            $sessionId = New-SessionId
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
        if ($inputText -match '^/model\s+(\S+)(?:\s+(\S+))?\s*$') {
            $nextModel = $Matches[1]
            $nextReasoning = if ($Matches.ContainsKey(2) -and $Matches[2]) {
                $Matches[2].ToLowerInvariant()
            }
            else {
                ''
            }
            if ($nextModel -ne 'auto' -and $nextModel -notin $availableModelIds) {
                Write-Host "Unknown model '$nextModel'. Use /models to list available IDs." `
                    -ForegroundColor Red
                continue
            }
            if ($nextReasoning) {
                if ($nextModel -eq 'auto') {
                    Write-Host 'Select a specific model when setting reasoning.' `
                        -ForegroundColor Red
                    continue
                }
                $supportedReasoning = @(Get-ModelReasoningModes `
                    -Models $models -ModelId $nextModel)
                if ($nextReasoning -notin $supportedReasoning) {
                    $available = if ($supportedReasoning.Count) {
                        $supportedReasoning -join ', '
                    }
                    else {
                        'none'
                    }
                    Write-Host (
                        "Model '$nextModel' does not support reasoning '$nextReasoning'. " +
                        "Available: $available."
                    ) -ForegroundColor Red
                    continue
                }
                $ReasoningEffort = $nextReasoning
                $reasoningEffortWasSpecified = $true
            }
            else {
                $reasoningEffortWasSpecified = $false
            }
            $Model = $nextModel
            $effectiveReasoningEffort = Get-EffectiveReasoningEffort -SelectedModel $Model `
                -RequestedEffort $ReasoningEffort -WasSpecified $reasoningEffortWasSpecified
            $reasoningStatus = if ($effectiveReasoningEffort) {
                $effectiveReasoningEffort
            }
            else {
                'model-default'
            }
            $messages = New-MessageHistory -Root $root -Mode $Mode
            $sessionId = New-SessionId
            Write-Host "Started a new conversation with $Model (reasoning: $reasoningStatus)." `
                -ForegroundColor DarkGray
            continue
        }
        if ($inputText -match '^/model\b') {
            Write-Host 'Usage: /model <id> [reasoning]. Use /models to see valid values.' `
                -ForegroundColor Red
            continue
        }
        if ($inputText -match '^/prompt\s+(.+)$') {
            $promptArg = $Matches[1].Trim()
            $promptPath = $promptArg
            if (($promptPath.StartsWith('"') -and $promptPath.EndsWith('"')) -or
                ($promptPath.StartsWith("'") -and $promptPath.EndsWith("'"))) {
                $promptPath = $promptPath.Substring(1, $promptPath.Length - 2)
            }
            if (-not [System.IO.Path]::IsPathRooted($promptPath)) {
                $promptPath = Join-Path $root $promptPath
            }
            $resolvedPrompt = Resolve-Path -LiteralPath $promptPath -ErrorAction SilentlyContinue
            if (-not $resolvedPrompt -or
                -not (Test-Path -LiteralPath $resolvedPrompt.Path -PathType Leaf)) {
                Write-Host "Prompt file not found: $promptArg" -ForegroundColor Red
                continue
            }
            $promptFileInput = [System.IO.File]::ReadAllText($resolvedPrompt.Path)
            if (-not $promptFileInput.Trim()) {
                Write-Host "Prompt file is empty: $promptArg" -ForegroundColor Red
                continue
            }
            Write-Host "Loaded prompt from $($resolvedPrompt.Path)" -ForegroundColor DarkGray
            $inputText = $promptFileInput
        }
        elseif ($inputText -match '^/prompt\b') {
            Write-Host 'Usage: /prompt <path>' -ForegroundColor Red
            continue
        }

        Write-Host ''
        Write-Host 'Status: working' -ForegroundColor Cyan
        Write-Host 'Assistant:' -ForegroundColor Green
        try {
            try {
                Invoke-AgentTurn -Connection $connection -SelectedModel $Model `
                    -Messages $messages -Text $inputText -Root $root `
                    -ApproveAutomatically ([bool]$AutoApprove) `
                    -AllowOutsideWorkspace ([bool]$AllowOutsideWorkspace) `
                    -DisableTools ([bool]$NoTools) -Mode $Mode -McpState $mcpState `
                    -Effort $effectiveReasoningEffort -StepLimit $MaxAgentSteps
            }
            catch {
                if (-not (Get-TransientTransportException -Exception $_.Exception)) {
                    throw
                }
                Write-Host ''
                Write-Host $_.Exception.Message -ForegroundColor Yellow
            }
        }
        finally {
            Write-Host 'Status: idle' -ForegroundColor DarkGray
            if (-not $NoSessionHistory) {
                try {
                    Save-Session -Id $sessionId -Messages $messages -Model $Model `
                        -Mode $Mode -Root $root
                }
                catch {
                    Write-Host "Could not save session: $($_.Exception.Message)" `
                        -ForegroundColor DarkGray
                }
            }
        }
    }
}
finally {
    Close-McpConnections -State $mcpState
}
