function Invoke-AgentTurn {
    param(
        [pscustomobject] $Connection,
        [string] $SelectedModel,
        [System.Collections.Generic.List[object]] $Messages,
        [string] $Text,
        [string] $Root,
        [bool] $ApproveAutomatically,
        [bool] $AllowOutsideWorkspace,
        [bool] $DisableTools,
        [ValidateSet('build', 'plan')]
        [string] $Mode,
        [pscustomobject] $McpState,
        [string] $Effort,
        [int] $StepLimit
    )

    $Messages.Add(@{ role = 'user'; content = $Text })

    for ($step = 1; $step -le $StepLimit; $step++) {
        $response = Invoke-CopilotChat -Connection $Connection `
            -SelectedModel $SelectedModel -Messages $Messages `
            -DisableTools $DisableTools -Mode $Mode -McpState $McpState -Effort $Effort
        $content = [string](Get-PropertyValue -Object $response -Name 'content' -Default '')
        $reasoningText = [string](Get-PropertyValue -Object $response `
            -Name 'reasoning_text' -Default '')
        $opaqueReasoning = [string](Get-PropertyValue -Object $response `
            -Name 'reasoning_opaque' -Default '')
        $toolCalls = @(Get-PropertyValue -Object $response -Name 'tool_calls' -Default @())

        $assistantMessage = [ordered]@{
            role    = 'assistant'
            content = if ($content) { $content } else { $null }
        }
        if ($reasoningText) {
            $assistantMessage.reasoning_text = $reasoningText
        }
        if ($opaqueReasoning) {
            $assistantMessage.reasoning_opaque = $opaqueReasoning
        }
        if ($toolCalls.Count -gt 0) {
            $assistantMessage.tool_calls = $toolCalls
        }
        $responsesOutput = @(Get-PropertyValue -Object $response `
            -Name 'responses_output' -Default @())
        if ($responsesOutput.Count -gt 0) {
            $assistantMessage.responses_output = $responsesOutput
        }
        $Messages.Add($assistantMessage)

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
                    $result = if (Test-McpTool -State $McpState -Name $name) {
                        Invoke-McpTool -State $McpState -Name $name `
                            -Arguments $arguments -Mode $Mode
                    }
                    else {
                        Invoke-AgentTool -Name $name -Arguments $arguments `
                            -Root $Root -Mode $Mode `
                            -AllowOutsideWorkspace:$AllowOutsideWorkspace
                    }
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

function Get-EffectiveReasoningEffort {
    param(
        [string] $SelectedModel,
        [string] $RequestedEffort,
        [bool] $WasSpecified
    )

    if ($WasSpecified) {
        return $RequestedEffort
    }
    if ($SelectedModel -eq 'claude-opus-4.8') {
        return 'max'
    }
    return ''
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
