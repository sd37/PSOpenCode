# Dependency-free agent regression checks. Run with pwsh -File tests/Agent.Tests.ps1.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
foreach ($source in @('Common', 'Agent')) {
    . (Join-Path $repo "src/$source.ps1")
}

function Assert-True {
    param([bool] $Condition, [string] $Description)
    if (-not $Condition) { throw "FAIL: $Description" }
}

$script:modelCalls = 0
$script:toolCalls = 0
$script:complete = $false
function Invoke-CopilotChat {
    $script:modelCalls++
    if ($script:complete) {
        return @{ content = 'Finished.' }
    }
    return @{ tool_calls = @(foreach ($index in 1..2) {
        @{ id = "call_${script:modelCalls}_$index"; function = @{
            name = 'read_file'; arguments = '{"path":"README.md"}'
        } }
    }) }
}
function Confirm-ToolCall { return $true }
function Test-McpTool { return $false }
function Invoke-AgentTool {
    $script:toolCalls++
    return "Result $script:toolCalls"
}

$messages = New-MessageHistory -Root $repo -Mode build
$parameters = @{
    Messages = $messages; Root = $repo; Mode = 'build'; StepLimit = 2
}
$notice = (Invoke-AgentTurn @parameters -Text 'Inspect files' 6>&1 | Out-String)
Assert-True ($script:modelCalls -eq 2) 'Stops at the configured model-call limit'
Assert-True ($script:toolCalls -eq 4) 'Completes every tool call, including the final batch'
Assert-True ($notice -match 'Agent paused' -and $notice -match 'continue') 'Explains how to resume'
Assert-True ($messages.Count -eq 8) 'Retains conversation at the limit'
foreach ($index in @(2, 5)) {
    foreach ($offset in 1..2) {
        Assert-True ($messages[$index + $offset].tool_call_id -eq
            $messages[$index].tool_calls[$offset - 1].id) 'Every tool call has a matching result'
    }
}

$null = Invoke-AgentTurn @parameters -Text 'continue' 6>&1
Assert-True ($script:modelCalls -eq 4 -and $script:toolCalls -eq 8) 'Continuation gets a fresh budget'
Assert-True ($messages[8].content -eq 'continue' -and
    $messages[7].content -eq 'Result 4') 'Continuation preserves previous tool results'

$script:complete = $true
$notice = (Invoke-AgentTurn @parameters -Text 'Summarize' 6>&1 | Out-String)
Assert-True ($script:modelCalls -eq 5 -and $script:toolCalls -eq 8) 'Normal completion stops early'
Assert-True ($messages[$messages.Count - 1].content -eq 'Finished.') 'Final answer retained'
Assert-True ($notice -notmatch 'Agent paused') 'Normal completion does not report a limit'

Write-Host 'PASS: step-limit pause, complete tool history, continuation, and normal completion.'
