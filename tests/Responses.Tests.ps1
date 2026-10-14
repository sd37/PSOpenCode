# Dependency-free transport regression checks. Run with pwsh -File tests/Responses.Tests.ps1.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
foreach ($source in @('Common', 'Copilot', 'Responses', 'Session')) {
    . (Join-Path $repo "src/$source.ps1")
}

function Assert-True {
    param([bool] $Condition, [string] $Description)
    if (-not $Condition) { throw "FAIL: $Description" }
}

foreach ($file in @((Get-Item (Join-Path $repo 'psopencode.ps1'))) +
    @(Get-ChildItem (Join-Path $repo 'src') -Filter '*.ps1')) {
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName, [ref]$null, [ref]$parseErrors
    )
    Assert-True (-not $parseErrors) "Syntax: $($file.Name)"
}

$connection = [pscustomobject]@{ ModelEndpoints = @{
    astra = @('/responses', 'ws:/responses')
    claude = @('/v1/messages', '/chat/completions')
    unsupported = @('/v1/messages')
} }
Assert-True ((Get-CopilotModelEndpoint $connection 'astra') -eq '/responses') 'Responses routing'
Assert-True ((Get-CopilotModelEndpoint $connection 'claude') -eq '/chat/completions') 'Chat routing'
Assert-True ((Get-CopilotModelEndpoint $connection 'auto') -eq '/chat/completions') 'Auto routing'
$rejected = $false
try { Get-CopilotModelEndpoint $connection 'unsupported' | Out-Null }
catch { $rejected = $_.Exception.Message -match 'supported HTTP' }
Assert-True $rejected 'Unsupported endpoint fails clearly'

$native = @(
    @{ type = 'reasoning'; id = 'rs_1'; summary = @(); encrypted_content = 'opaque-test-value' },
    @{ type = 'function_call'; id = 'fc_1'; call_id = 'call_1'; name = 'read_file'
        arguments = '{"path":"README.md"}'; status = 'completed' },
    @{ type = 'function_call'; id = 'fc_2'; call_id = 'call_2'; name = 'read_file'
        arguments = '{"path":"src/Agent.ps1"}'; status = 'completed' }
)
$event = @{ type = 'response.completed'; response = @{ output = $native; status = 'completed' } }
$sse = "event: response.completed`n" + 'data: ' + ($event | ConvertTo-Json -Depth 100 -Compress) + "`n`n"
$reader = [System.IO.StringReader]::new($sse)
try { $result = Read-CopilotResponsesStream $reader }
finally { $reader.Dispose() }
Assert-True ($result.tool_calls.Count -eq 2) 'Parallel tool calls parsed'
Assert-True ($result.tool_calls[0].id -eq 'call_1') 'call_id used instead of output item id'

$history = [System.Collections.Generic.List[object]]::new()
$history.Add(@{ role = 'system'; content = 'Instructions' })
$history.Add(@{ role = 'user'; content = 'Read these files' })
$history.Add(@{ role = 'assistant'; content = $null; tool_calls = $result.tool_calls
    responses_output = $result.responses_output })
$history.Add(@{ role = 'tool'; tool_call_id = 'call_1'; content = 'First result' })
$history.Add(@{ role = 'tool'; tool_call_id = 'call_2'; content = 'Second result' })
$chatBody = [ordered]@{ model = 'astra'; reasoning_effort = 'max'; tools = @(
    @{ type = 'function'; function = @{ name = 'read_file'; description = 'Read a file'
        parameters = @{ type = 'object'; properties = @{ path = @{ type = 'string' } } } } }
) }
$body = ConvertTo-ResponsesBody $chatBody $history
Assert-True ($body.input.Count -eq 7) 'No duplicated assistant function calls'
Assert-True ($body.input[2].encrypted_content -eq 'opaque-test-value') 'Encrypted reasoning replay'
Assert-True ($body.input[5].call_id -eq 'call_1') 'First tool result links to call'
Assert-True ($body.input[6].output -eq 'Second result') 'Second tool result replay'
Assert-True ($body.reasoning.effort -eq 'max') 'Nested reasoning effort'
Assert-True ($body.tools[0].name -eq 'read_file' -and -not $body.tools[0].strict) 'Responses tool schema'
Assert-True (-not $body.store) 'Stateless request'
Assert-True (($body.include -join ',') -eq 'reasoning.encrypted_content') 'Encrypted reasoning requested'

$chat = @(ConvertTo-ChatMessages $history)
Assert-True (-not $chat[2].Contains('responses_output')) 'Native metadata excluded from Chat API'
Assert-True ($chat[2].tool_calls.Count -eq 2) 'Chat tool calls retained'
$legacy = [System.Collections.Generic.List[object]]::new()
foreach ($message in $chat) { $legacy.Add($message) }
$legacyBody = ConvertTo-ResponsesBody $chatBody $legacy
Assert-True ($legacyBody.input[2].type -eq 'function_call') 'Legacy chat history translates to Responses'

# Exercise the real session writer/loader using a temporary, isolated path.
$script:testDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('psoc-responses-' + [guid]::NewGuid())
function Get-SessionDirectory { return $script:testDirectory }
try {
    Save-Session -Id 'test' -Messages $history -Model 'astra' -Mode 'build' -Root $repo
    $loaded = Import-Session -Id 'test'
    $replayed = ConvertTo-ResponsesBody $chatBody $loaded.Messages
    Assert-True (($body | ConvertTo-Json -Depth 100 -Compress) -eq
        ($replayed | ConvertTo-Json -Depth 100 -Compress)) 'Saved session request round-trip'
}
finally {
    if (Test-Path $script:testDirectory) { Remove-Item $script:testDirectory -Recurse -Force }
}

foreach ($case in @(
    @{ Text = ''; Received = $false },
    @{ Text = 'data: {"type":"response.created"}'; Received = $true }
)) {
    $reader = [System.IO.StringReader]::new($case.Text)
    $failure = $null
    try { Read-CopilotResponsesStream $reader | Out-Null }
    catch { $failure = Get-TransientTransportException $_.Exception }
    finally { $reader.Dispose() }
    Assert-True ($null -ne $failure) 'Truncated stream rejected'
    Assert-True ($failure.Data['ReceivedEvent'] -eq $case.Received) 'Retry flag reflects received events'
}
foreach ($type in @('response.failed', 'response.incomplete', 'error')) {
    $reader = [System.IO.StringReader]::new('data: {"type":"' + $type + '"}')
    $rejected = $false
    try { Read-CopilotResponsesStream $reader | Out-Null }
    catch { $rejected = $_.Exception.Message -like "*${type}*" }
    finally { $reader.Dispose() }
    Assert-True $rejected "API failure propagated: $type"
}
Write-Host 'PASS: endpoint routing, request conversion, tools, saved history, and stream failures.'
