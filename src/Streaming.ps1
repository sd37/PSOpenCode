function Invoke-CopilotChatAttempt {
    param(
        [pscustomobject] $Connection,
        [string] $SelectedModel,
        [System.Collections.Generic.List[object]] $Messages,
        [bool] $DisableTools,
        [ValidateSet('build', 'plan')]
        [string] $Mode,
        [pscustomobject] $McpState,
        [string] $Effort
    )

    $endpoint = Get-CopilotModelEndpoint -Connection $Connection -Model $SelectedModel
    $body = [ordered]@{
        model    = $SelectedModel
        messages = @(ConvertTo-ChatMessages -Messages $Messages)
        stream   = $true
    }
    if (-not $DisableTools) {
        $toolDefinitions = @(
            @(Get-ToolDefinitions -Mode $Mode)
            @(Get-McpToolDefinitions -State $McpState -Mode $Mode)
        )
        if ($toolDefinitions.Count -gt 0) {
            $body.tools = $toolDefinitions
            $body.tool_choice = 'auto'
        }
    }
    if ($Effort) {
        $body.reasoning_effort = $Effort
    }
    if ($endpoint -eq '/responses') {
        $body = ConvertTo-ResponsesBody -ChatBody $body -Messages $Messages
    }

    $headers = Get-CopilotHeaders -Token $Connection.Token
    $headers['Accept'] = 'text/event-stream'
    $headers['x-initiator'] = if ($Messages.Count -gt 2) { 'agent' } else { 'user' }

    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromMinutes(30)
    $request = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::Post,
        "$($Connection.ApiBase)$endpoint"
    )
    $response = $null
    try {
        foreach ($entry in $headers.GetEnumerator()) {
            if (-not $request.Headers.TryAddWithoutValidation(
                [string]$entry.Key,
                [string]$entry.Value
            )) {
                throw "Invalid HTTP header: $($entry.Key)"
            }
        }
        $json = $body | ConvertTo-Json -Compress -Depth 100
        $request.Content = [System.Net.Http.StringContent]::new(
            $json,
            [System.Text.UTF8Encoding]::new($false),
            'application/json'
        )

        $response = $client.SendAsync(
            $request,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
        ).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            $errorBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if ([int]$response.StatusCode -eq 401 -and
                $errorBody -match '(?i)(IDE token|token).*(expired|unauthorized)') {
                $tokenException = [System.UnauthorizedAccessException]::new(
                    "The Copilot IDE token expired: $errorBody"
                )
                $tokenException.Data['CopilotTokenExpired'] = $true
                throw $tokenException
            }
            throw "Calling Copilot model '$SelectedModel' failed with HTTP " +
                "$([int]$response.StatusCode)`: $errorBody"
        }

        if ($endpoint -eq '/responses') {
            $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $reader = [System.IO.StreamReader]::new($stream)
            try {
                return Read-CopilotResponsesStream -Reader $reader
            }
            finally {
                $reader.Dispose()
            }
        }

        $contentBuilder = [System.Text.StringBuilder]::new()
        $reasoningBuilder = [System.Text.StringBuilder]::new()
        $opaqueReasoningBuilder = [System.Text.StringBuilder]::new()
        $toolCallBuilders = [System.Collections.Generic.Dictionary[int, object]]::new()
        $thinkingStarted = $false
        $contentStarted = $false
        $receivedEvent = $false

        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $reader = [System.IO.StreamReader]::new($stream)
        try {
            while (($line = $reader.ReadLine()) -ne $null) {
                if (-not $line.StartsWith('data:', [StringComparison]::Ordinal)) {
                    continue
                }

                $data = $line.Substring(5).TrimStart()
                if (-not $data) {
                    continue
                }
                if ($data -eq '[DONE]') {
                    break
                }

                try {
                    $event = $data | ConvertFrom-Json -Depth 100
                }
                catch {
                    throw "Copilot returned an invalid streaming event: $($_.Exception.Message)"
                }
                $receivedEvent = $true

                $choices = @(Get-PropertyValue -Object $event -Name 'choices' -Default @())
                if ($choices.Count -eq 0) {
                    continue
                }
                $delta = Get-PropertyValue -Object $choices[0] -Name 'delta'
                if (-not $delta) {
                    continue
                }

                $reasoning = [string](Get-PropertyValue -Object $delta `
                    -Name 'reasoning_text' -Default '')
                if ($reasoning) {
                    if (-not $thinkingStarted) {
                        Write-Host 'Thinking:' -ForegroundColor DarkGray
                        $thinkingStarted = $true
                    }
                    Write-Host $reasoning -NoNewline -ForegroundColor DarkGray
                    [void]$reasoningBuilder.Append($reasoning)
                }

                $opaqueReasoning = [string](Get-PropertyValue -Object $delta `
                    -Name 'reasoning_opaque' -Default '')
                if ($opaqueReasoning) {
                    [void]$opaqueReasoningBuilder.Append($opaqueReasoning)
                }

                $content = [string](Get-PropertyValue -Object $delta `
                    -Name 'content' -Default '')
                if ($content) {
                    if (-not $contentStarted) {
                        if ($thinkingStarted) {
                            Write-Host ''
                            Write-Host ''
                            Write-Host 'Response:' -ForegroundColor Green
                        }
                        $contentStarted = $true
                    }
                    Write-Host $content -NoNewline
                    [void]$contentBuilder.Append($content)
                }

                $toolCallDeltas = @(Get-PropertyValue -Object $delta `
                    -Name 'tool_calls' -Default @())
                foreach ($toolCallDelta in $toolCallDeltas) {
                    $index = [int](Get-PropertyValue -Object $toolCallDelta `
                        -Name 'index' -Default 0)
                    if (-not $toolCallBuilders.ContainsKey($index)) {
                        $toolCallBuilders[$index] = [ordered]@{
                            id       = ''
                            type     = 'function'
                            function = [ordered]@{
                                name      = ''
                                arguments = ''
                            }
                        }
                    }

                    $toolCall = $toolCallBuilders[$index]
                    $id = [string](Get-PropertyValue -Object $toolCallDelta `
                        -Name 'id' -Default '')
                    if ($id) {
                        $toolCall.id += $id
                    }
                    $type = [string](Get-PropertyValue -Object $toolCallDelta `
                        -Name 'type' -Default '')
                    if ($type) {
                        $toolCall.type = $type
                    }

                    $functionDelta = Get-PropertyValue -Object $toolCallDelta `
                        -Name 'function'
                    if ($functionDelta) {
                        $name = [string](Get-PropertyValue -Object $functionDelta `
                            -Name 'name' -Default '')
                        $arguments = [string](Get-PropertyValue -Object $functionDelta `
                            -Name 'arguments' -Default '')
                        if ($name) {
                            $toolCall.function.name += $name
                        }
                        if ($arguments) {
                            $toolCall.function.arguments += $arguments
                        }
                    }
                }
            }
        }
        catch {
            $transportException = Get-TransientTransportException -Exception $_.Exception
            if (-not $transportException) {
                throw
            }
            $streamException = [System.IO.IOException]::new(
                "The Copilot stream was interrupted: $($transportException.Message)",
                $transportException
            )
            $streamException.Data['ReceivedEvent'] = $receivedEvent
            throw $streamException
        }
        finally {
            $reader.Dispose()
        }

        if (-not $receivedEvent) {
            throw "Copilot model '$SelectedModel' returned an empty stream."
        }
        if ($thinkingStarted -or $contentStarted) {
            Write-Host ''
        }

        $toolCalls = @($toolCallBuilders.GetEnumerator() |
            Sort-Object Key |
            ForEach-Object { $_.Value })
        return [pscustomobject]@{
            content          = $contentBuilder.ToString()
            reasoning_text   = $reasoningBuilder.ToString()
            reasoning_opaque = $opaqueReasoningBuilder.ToString()
            tool_calls       = $toolCalls
        }
    }

    finally {
        if ($response) {
            $response.Dispose()
        }
        $request.Dispose()
        $client.Dispose()
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
        [pscustomobject] $McpState,
        [string] $Effort
    )

    $maxAttempts = 3
    if (Test-CopilotTokenNeedsRefresh -Connection $Connection) {
        Write-Host 'Refreshing Copilot session token...' -ForegroundColor DarkGray
        Update-CopilotConnection -Connection $Connection
    }
    $tokenRefreshAttempted = $false
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            return Invoke-CopilotChatAttempt -Connection $Connection `
                -SelectedModel $SelectedModel -Messages $Messages `
                -DisableTools $DisableTools -Mode $Mode -McpState $McpState `
                -Effort $Effort
        }
        catch {
            if (Test-CopilotTokenExpiredException -Exception $_.Exception) {
                if ($tokenRefreshAttempted) {
                    throw
                }
                Write-Host 'Refreshing expired Copilot session token...' `
                    -ForegroundColor DarkGray
                Update-CopilotConnection -Connection $Connection
                $tokenRefreshAttempted = $true
                $attempt--
                continue
            }
            $transportException = Get-TransientTransportException -Exception $_.Exception
            if (-not $transportException) {
                throw
            }
            $receivedEvent = [bool]$transportException.Data['ReceivedEvent']
            if ($receivedEvent) {
                throw [System.IO.IOException]::new(
                    'The Copilot connection was interrupted after output began. ' +
                    'The request was not retried to avoid duplicating the response. ' +
                    'Submit a follow-up message to continue.',
                    $transportException
                )
            }
            if ($attempt -eq $maxAttempts) {
                throw [System.IO.IOException]::new(
                    "The Copilot connection failed after $maxAttempts attempts: " +
                    $transportException.Message,
                    $transportException
                )
            }
            Write-Host (
                "Copilot connection interrupted before output; retrying " +
                "($attempt/$maxAttempts)..."
            ) -ForegroundColor DarkGray
            Start-Sleep -Seconds $attempt
        }
    }
}
