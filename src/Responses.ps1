function ConvertTo-ChatMessages {
    param([System.Collections.Generic.List[object]] $Messages)

    foreach ($message in $Messages) {
        # Responses output is local history metadata, not a Chat Completions field.
        $copy = [ordered]@{}
        $names = if ($message -is [System.Collections.IDictionary]) {
            @($message.Keys)
        }
        else {
            @($message.PSObject.Properties.Name)
        }
        foreach ($name in $names) {
            if ($name -ne 'responses_output') {
                $copy[$name] = Get-PropertyValue -Object $message -Name $name
            }
        }
        $copy
    }
}

function ConvertTo-ResponsesBody {
    param(
        [System.Collections.IDictionary] $ChatBody,
        [System.Collections.Generic.List[object]] $Messages
    )

    $inputItems = [System.Collections.Generic.List[object]]::new()
    foreach ($message in $Messages) {
        $role = [string](Get-PropertyValue -Object $message -Name 'role')
        $content = [string](Get-PropertyValue -Object $message -Name 'content')
        $nativeOutput = @(Get-PropertyValue -Object $message -Name 'responses_output' -Default @())
        if ($role -eq 'assistant' -and $nativeOutput.Count -gt 0) {
            # Replay native items, including encrypted reasoning and function calls.
            foreach ($item in $nativeOutput) {
                $inputItems.Add($item)
            }
            continue
        }
        if ($role -eq 'tool') {
            $inputItems.Add(@{
                type = 'function_call_output'
                call_id = [string](Get-PropertyValue -Object $message -Name 'tool_call_id')
                output = $content
            })
            continue
        }
        if ($content) {
            $inputItems.Add(@{ role = $role; content = $content })
        }
        if ($role -eq 'assistant') {
            foreach ($call in @(Get-PropertyValue -Object $message -Name 'tool_calls' -Default @())) {
                $inputItems.Add(@{
                    type = 'function_call'
                    call_id = $call.id
                    name = $call.function.name
                    arguments = $call.function.arguments
                })
            }
        }
    }

    $body = [ordered]@{
        model = $ChatBody.model
        input = @($inputItems)
        stream = $true
        store = $false
        include = @('reasoning.encrypted_content')
    }
    if ($ChatBody.Contains('reasoning_effort')) {
        $body.reasoning = @{ effort = $ChatBody.reasoning_effort; summary = 'auto' }
    }
    if ($ChatBody.Contains('tools')) {
        $body.tools = @($ChatBody.tools | ForEach-Object {
            @{
                type = 'function'
                name = $_.function.name
                description = $_.function.description
                parameters = $_.function.parameters
                strict = $false
            }
        })
        $body.tool_choice = 'auto'
    }
    return $body
}

function Read-CopilotResponsesStream {
    param([System.IO.TextReader] $Reader)

    $receivedEvent = $false
    $thinkingStarted = $false
    $contentStarted = $false
    $reasoning = [System.Text.StringBuilder]::new()
    $completed = $null
    try {
        while (($line = $Reader.ReadLine()) -ne $null) {
            if (-not $line.StartsWith('data:', [StringComparison]::Ordinal)) {
                continue
            }
            $data = $line.Substring(5).TrimStart()
            if (-not $data) { continue }
            if ($data -eq '[DONE]') { break }
            $receivedEvent = $true
            $event = $data | ConvertFrom-Json -Depth 100
            $type = [string](Get-PropertyValue -Object $event -Name 'type')
            switch ($type) {
                'response.reasoning_summary_text.delta' {
                    if (-not $thinkingStarted) {
                        Write-Host 'Thinking:' -ForegroundColor DarkGray
                        $thinkingStarted = $true
                    }
                    Write-Host $event.delta -NoNewline -ForegroundColor DarkGray
                    [void]$reasoning.Append($event.delta)
                }
                { $_ -in @('response.output_text.delta', 'response.refusal.delta') } {
                    if (-not $contentStarted -and $thinkingStarted) {
                        Write-Host "`n`nResponse:" -ForegroundColor Green
                    }
                    $contentStarted = $true
                    Write-Host $event.delta -NoNewline
                }
                'response.completed' {
                    $completed = $event.response
                }
                { $_ -in @('response.failed', 'response.incomplete', 'error') } {
                    throw "Copilot Responses API returned ${type}: $data"
                }
            }
            if ($null -ne $completed) { break }
        }
        if ($null -eq $completed) {
            throw [System.IO.IOException]::new('Copilot Responses stream ended before response.completed.')
        }
    }
    catch {
        $transportException = Get-TransientTransportException -Exception $_.Exception
        if ($transportException) {
            $streamException = [System.IO.IOException]::new(
                "The Copilot Responses stream was interrupted: $($transportException.Message)",
                $transportException
            )
            $streamException.Data['ReceivedEvent'] = $receivedEvent
            throw $streamException
        }
        throw
    }
    finally {
        if ($thinkingStarted -or $contentStarted) { Write-Host '' }
    }

    $output = @(Get-PropertyValue -Object $completed -Name 'output' -Default @())
    $text = [System.Text.StringBuilder]::new()
    $calls = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $output) {
        switch ($item.type) {
            'message' {
                foreach ($part in $item.content) {
                    if ($part.type -eq 'output_text') {
                        [void]$text.Append($part.text)
                    }
                    elseif ($part.type -eq 'refusal') {
                        [void]$text.Append($part.refusal)
                    }
                }
            }
            'function_call' {
                $calls.Add(@{
                    id = $item.call_id
                    type = 'function'
                    function = @{ name = $item.name; arguments = $item.arguments }
                })
            }
        }
    }
    return [pscustomobject]@{
        content = $text.ToString()
        reasoning_text = $reasoning.ToString()
        tool_calls = @($calls)
        responses_output = $output
    }
}
