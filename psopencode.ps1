#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments)]
    [string[]] $Prompt,

    [Alias('m')]
    [string] $Model = 'claude-opus-4.8',

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
    [string] $ReasoningEffort = 'high',

    [ValidateRange(1, 100)]
    [int] $MaxAgentSteps = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$reasoningEffortWasSpecified = $PSBoundParameters.ContainsKey('ReasoningEffort')

$script:ApiVersion = '2025-04-01'
$script:CopilotVersion = '0.26.7'
$script:OAuthClientId = 'Iv1.b507a08c87ecfe98'

$sourceFiles = @(
    'src\Common.ps1'
    'src\Auth.ps1'
    'src\Tools.ps1'
    'src\Copilot.ps1'
    'src\Streaming.ps1'
    'src\Agent.ps1'
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
$effectiveReasoningEffort = Get-EffectiveReasoningEffort -SelectedModel $Model `
    -RequestedEffort $ReasoningEffort -WasSpecified $reasoningEffortWasSpecified
$reasoningStatus = if ($effectiveReasoningEffort) {
    $effectiveReasoningEffort
}
else {
    'model-default'
}

$root = (Resolve-Path -LiteralPath $WorkingDirectory).Path
$messages = New-MessageHistory -Root $root -Mode $Mode
$singlePrompt = ($Prompt -join ' ').Trim()

if ($singlePrompt) {
    Invoke-AgentTurn -Connection $connection -SelectedModel $Model -Messages $messages `
        -Text $singlePrompt -Root $root -ApproveAutomatically ([bool]$AutoApprove) `
        -DisableTools ([bool]$NoTools) -Mode $Mode -Effort $effectiveReasoningEffort `
        -StepLimit $MaxAgentSteps
    return
}

Write-Host (
    "PSOpenCode | $HostName | model: $Model | reasoning: $reasoningStatus | " +
    "mode: $Mode | cwd: $root"
) -ForegroundColor Cyan
Write-Host 'Commands: /help, /mode [build|plan], /models, /model <id>, /new, /exit'

while ($true) {
    $inputText = Read-Host "`nYou [$Mode | reasoning: $reasoningStatus]"
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
        $effectiveReasoningEffort = Get-EffectiveReasoningEffort -SelectedModel $Model `
            -RequestedEffort $ReasoningEffort -WasSpecified $reasoningEffortWasSpecified
        $reasoningStatus = if ($effectiveReasoningEffort) {
            $effectiveReasoningEffort
        }
        else {
            'model-default'
        }
        $messages = New-MessageHistory -Root $root -Mode $Mode
        Write-Host "Started a new conversation with $Model (reasoning: $reasoningStatus)." `
            -ForegroundColor DarkGray
        continue
    }

    Write-Host ''
    Write-Host 'Assistant:' -ForegroundColor Green
    Invoke-AgentTurn -Connection $connection -SelectedModel $Model -Messages $messages `
        -Text $inputText -Root $root -ApproveAutomatically ([bool]$AutoApprove) `
        -DisableTools ([bool]$NoTools) -Mode $Mode -Effort $effectiveReasoningEffort `
        -StepLimit $MaxAgentSteps
}
