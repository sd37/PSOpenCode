function Resolve-McpTemplate {
    param(
        [string] $Value,
        [string] $ServerName,
        [switch] $AllowPrompt
    )

    $resolved = $Value
    foreach ($match in [regex]::Matches($Value, '\$\{([A-Za-z_][A-Za-z0-9_]*)\}')) {
        $variableName = $match.Groups[1].Value
        $environmentValue = [Environment]::GetEnvironmentVariable($variableName)
        if ([string]::IsNullOrEmpty($environmentValue) -and $AllowPrompt) {
            $environmentValue = Get-McpLocalSetting -Name $variableName
        }
        if ([string]::IsNullOrEmpty($environmentValue) -and $AllowPrompt) {
            Write-Host ''
            Write-Host "Configure MCP server '$ServerName'." -ForegroundColor Cyan
            $environmentValue = (Read-Host "$variableName").Trim()
            if (-not $environmentValue) {
                throw "MCP server '$ServerName' requires '$variableName'."
            }
            Save-McpLocalSetting -Name $variableName -Value $environmentValue
        }
        if ([string]::IsNullOrEmpty($environmentValue)) {
            throw "MCP server '$ServerName' requires environment variable '$variableName'."
        }
        $resolved = $resolved.Replace($match.Value, $environmentValue)
    }
    return $resolved
}

function Get-McpConnectionSettings {
    param([pscustomobject] $Server)

    $urlTemplate = [string](Get-PropertyValue -Object $Server.Config -Name 'url')
    if (-not $urlTemplate) {
        throw "MCP server '$($Server.Name)' does not define a URL."
    }
    $url = Resolve-McpTemplate -Value $urlTemplate -ServerName $Server.Name -AllowPrompt
    $uri = $null
    if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri)) {
        throw "MCP server '$($Server.Name)' has an invalid URL."
    }
    if ($uri.Scheme -ne 'https' -and
        -not ($uri.Scheme -eq 'http' -and $uri.IsLoopback)) {
        throw "MCP server '$($Server.Name)' must use HTTPS or loopback HTTP."
    }

    $headers = @{}
    $configuredHeaders = Get-PropertyValue -Object $Server.Config -Name 'headers'
    if ($configuredHeaders) {
        foreach ($property in $configuredHeaders.PSObject.Properties) {
            $headers[$property.Name] = Resolve-McpTemplate `
                -Value ([string]$property.Value) -ServerName $Server.Name
        }
    }
    $oauthManaged = $false
    $oauthExpiresAt = ''
    $authConfig = Get-PropertyValue -Object $Server.Config -Name 'auth'
    if (-not $headers.ContainsKey('Authorization') -and $authConfig) {
        $accessToken = Get-McpOAuthAccessToken -Server $Server -ResourceUri $uri
        if ($accessToken) {
            $headers.Authorization = "Bearer $accessToken"
            $oauthManaged = $true
            $credential = Get-McpOAuthCredential -ServerName $Server.Name
            if ($credential) {
                $oauthExpiresAt = $credential.ExpiresAt
            }
        }
    }

    return [pscustomobject]@{
        Uri            = $uri
        Headers        = $headers
        OAuthManaged   = $oauthManaged
        OAuthExpiresAt = $oauthExpiresAt
    }
}

function Update-McpOAuthAuthorization {
    param([pscustomobject] $Server)

    if (-not $Server.Settings.OAuthManaged) {
        return
    }
    $expiresAt = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse(
        [string]$Server.Settings.OAuthExpiresAt,
        [ref]$expiresAt
    ) -and $expiresAt -gt [DateTimeOffset]::UtcNow.AddMinutes(2)) {
        return
    }

    Write-Host "Refreshing MCP token for '$($Server.Name)'..." -ForegroundColor DarkGray
    $accessToken = Get-McpOAuthAccessToken -Server $Server `
        -ResourceUri $Server.Settings.Uri
    if (-not $accessToken) {
        throw "MCP server '$($Server.Name)' did not return an OAuth access token."
    }
    $Server.Settings.Headers.Authorization = "Bearer $accessToken"
    $credential = Get-McpOAuthCredential -ServerName $Server.Name
    $Server.Settings.OAuthExpiresAt = if ($credential) {
        $credential.ExpiresAt
    }
    else {
        ''
    }
}

function Get-McpExceptionStatusCode {
    param([Exception] $Exception)

    $current = $Exception
    while ($current) {
        $statusCode = Get-PropertyValue -Object $current -Name 'StatusCode'
        if ($null -ne $statusCode) {
            return [int]$statusCode
        }
        $current = $current.InnerException
    }
    return 0
}

function ConvertFrom-McpSseData {
    param(
        [string[]] $DataLines,
        [string] $ServerName
    )

    try {
        return ($DataLines -join "`n") | ConvertFrom-JsonText -Depth 100
    }
    catch {
        throw "MCP server '$ServerName' returned invalid SSE JSON: $($_.Exception.Message)"
    }
}

function Resolve-McpInboundMessage {
    param(
        [pscustomobject] $Server,
        [object] $Message,
        [object] $RequestId
    )

    if ((Get-PropertyValue -Object $Message -Name 'jsonrpc') -ne '2.0') {
        throw "MCP server '$($Server.Name)' returned a non-JSON-RPC 2.0 message."
    }

    $method = [string](Get-PropertyValue -Object $Message -Name 'method' -Default '')
    $messageId = Get-PropertyValue -Object $Message -Name 'id'
    if ($method) {
        if ($null -ne $messageId) {
            $response = if ($method -eq 'ping') {
                @{ jsonrpc = '2.0'; id = $messageId; result = @{} }
            }
            else {
                @{
                    jsonrpc = '2.0'
                    id      = $messageId
                    error   = @{
                        code    = -32601
                        message = "Client method '$method' is not supported."
                    }
                }
            }
            $null = Invoke-McpHttpMessage -Server $Server -Message $response -Notification
        }
        return $null
    }
    if ($null -ne $messageId -and $messageId -eq $RequestId) {
        return $Message
    }
    return $null
}

function Read-McpSseResponse {
    param(
        [pscustomobject] $Server,
        [System.IO.Stream] $Stream,
        [object] $RequestId
    )

    $reader = [System.IO.StreamReader]::new($Stream)
    $dataLines = [System.Collections.Generic.List[string]]::new()
    try {
        while (($line = $reader.ReadLine()) -ne $null) {
            if ($line.StartsWith('data:', [StringComparison]::Ordinal)) {
                $dataLines.Add($line.Substring(5).TrimStart())
                continue
            }
            if ($line.Length -ne 0 -or $dataLines.Count -eq 0) {
                continue
            }

            $message = ConvertFrom-McpSseData -DataLines $dataLines.ToArray() `
                -ServerName $Server.Name
            $dataLines.Clear()
            $matched = Resolve-McpInboundMessage -Server $Server `
                -Message $message -RequestId $RequestId
            if ($matched) {
                return $matched
            }
        }

        if ($dataLines.Count -gt 0) {
            $message = ConvertFrom-McpSseData -DataLines $dataLines.ToArray() `
                -ServerName $Server.Name
            $matched = Resolve-McpInboundMessage -Server $Server `
                -Message $message -RequestId $RequestId
            if ($matched) {
                return $matched
            }
        }
    }
    catch {
        $transportException = Get-TransientTransportException -Exception $_.Exception
        if (-not $transportException) {
            throw
        }
        throw [System.IO.IOException]::new(
            "MCP server '$($Server.Name)' interrupted its response stream. " +
            'The request was not retried because it may have completed: ' +
            $transportException.Message,
            $transportException
        )
    }
    finally {
        $reader.Dispose()
    }

    throw "MCP server '$($Server.Name)' closed its stream without a matching response."
}

function Invoke-McpHttpMessage {
    param(
        [pscustomobject] $Server,
        [hashtable] $Message,
        [object] $RequestId = $null,
        [switch] $Initialization,
        [switch] $Notification
    )

    if (-not $Server.Client) {
        throw "MCP server '$($Server.Name)' does not have an active HTTP client."
    }
    Update-McpOAuthAuthorization -Server $Server
    $request = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::Post,
        $Server.Settings.Uri
    )
    $response = $null
    try {
        foreach ($entry in $Server.Settings.Headers.GetEnumerator()) {
            if (-not $request.Headers.TryAddWithoutValidation(
                [string]$entry.Key,
                [string]$entry.Value
            )) {
                throw "Invalid MCP HTTP header: $($entry.Key)"
            }
        }
        $null = $request.Headers.TryAddWithoutValidation(
            'Accept',
            'application/json, text/event-stream'
        )
        if (-not $Initialization -and $Server.ProtocolVersion) {
            $null = $request.Headers.TryAddWithoutValidation(
                'MCP-Protocol-Version',
                $Server.ProtocolVersion
            )
        }
        if (-not $Initialization -and $Server.SessionId) {
            $null = $request.Headers.TryAddWithoutValidation(
                'Mcp-Session-Id',
                $Server.SessionId
            )
        }

        $json = $Message | ConvertTo-Json -Compress -Depth 100
        $request.Content = [System.Net.Http.StringContent]::new(
            $json,
            [System.Text.UTF8Encoding]::new($false),
            'application/json'
        )
        $response = $Server.Client.SendAsync(
            $request,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
        ).GetAwaiter().GetResult()

        if (-not $response.IsSuccessStatusCode) {
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            throw [System.Net.Http.HttpRequestException]::new(
                "MCP server '$($Server.Name)' returned HTTP " +
                    "$([int]$response.StatusCode): $body",
                $null,
                $response.StatusCode
            )
        }
        if ($Initialization) {
            $sessionValues = $null
            if ($response.Headers.TryGetValues('Mcp-Session-Id', [ref]$sessionValues)) {
                $Server.SessionId = [string]@($sessionValues)[0]
            }
        }
        if ($Notification) {
            if ([int]$response.StatusCode -ne 202) {
                throw "MCP server '$($Server.Name)' returned HTTP " +
                    "$([int]$response.StatusCode) instead of 202 for a notification."
            }
            $notificationBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if ($notificationBody) {
                throw "MCP server '$($Server.Name)' returned a body for a notification."
            }
            return $null
        }

        $contentType = $response.Content.Headers.ContentType
        $mediaType = if ($contentType) { [string]$contentType.MediaType } else { '' }
        if ($mediaType -eq 'text/event-stream') {
            $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            return Read-McpSseResponse -Server $Server -Stream $stream `
                -RequestId $RequestId
        }
        if ($mediaType -ne 'application/json') {
            throw "MCP server '$($Server.Name)' returned unsupported content type '$mediaType'."
        }
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        try {
            return $body | ConvertFrom-JsonText -Depth 100
        }
        catch {
            throw "MCP server '$($Server.Name)' returned invalid JSON: $($_.Exception.Message)"
        }
    }
    finally {
        if ($response) {
            $response.Dispose()
        }
        $request.Dispose()
    }
}

function Invoke-McpRequest {
    param(
        [pscustomobject] $Server,
        [string] $Method,
        [hashtable] $Params = @{},
        [switch] $Initialization
    )

    $requestId = $Server.NextRequestId
    $Server.NextRequestId++
    $message = @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = $Method
        params  = $Params
    }
    $response = Invoke-McpHttpMessage -Server $Server -Message $message `
        -RequestId $requestId -Initialization:$Initialization
    if (-not $response) {
        throw "MCP server '$($Server.Name)' returned no response for '$Method'."
    }
    if ((Get-PropertyValue -Object $response -Name 'jsonrpc') -ne '2.0') {
        throw "MCP server '$($Server.Name)' returned a non-JSON-RPC 2.0 response."
    }
    if ((Get-PropertyValue -Object $response -Name 'id') -ne $requestId) {
        throw "MCP server '$($Server.Name)' returned a mismatched response ID for '$Method'."
    }

    $errorObject = Get-PropertyValue -Object $response -Name 'error'
    $resultProperty = $response.PSObject.Properties['result']
    if ($errorObject -and $null -ne $resultProperty) {
        throw "MCP server '$($Server.Name)' returned both result and error for '$Method'."
    }
    if ($errorObject) {
        $code = Get-PropertyValue -Object $errorObject -Name 'code' -Default 'unknown'
        $messageText = Get-PropertyValue -Object $errorObject -Name 'message' `
            -Default 'Unknown MCP error'
        throw "MCP server '$($Server.Name)' failed '$Method' ($code): $messageText"
    }
    if ($null -eq $resultProperty) {
        throw "MCP server '$($Server.Name)' returned neither result nor error for '$Method'."
    }
    return $resultProperty.Value
}

function Send-McpNotification {
    param(
        [pscustomobject] $Server,
        [string] $Method,
        [hashtable] $Params = @{}
    )

    $message = @{
        jsonrpc = '2.0'
        method  = $Method
        params  = $Params
    }
    $null = Invoke-McpHttpMessage -Server $Server -Message $message -Notification
}

function Connect-McpServerTransport {
    param([pscustomobject] $Server)

    $initializeResult = $null
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $Server.Settings = Get-McpConnectionSettings -Server $Server
        if ($Server.Client) {
            $Server.Client.Dispose()
        }
        $Server.Client = [System.Net.Http.HttpClient]::new()
        $Server.Client.Timeout = [TimeSpan]::FromMinutes(5)
        $Server.SessionId = ''
        $Server.ProtocolVersion = ''
        try {
            $initializeResult = Invoke-McpRequest -Server $Server -Method 'initialize' `
                -Initialization -Params @{
                protocolVersion = '2025-06-18'
                capabilities    = @{}
                clientInfo      = @{
                    name    = 'PSOpenCode'
                    version = '1.0'
                }
            }
            break
        }
        catch {
            $statusCode = Get-McpExceptionStatusCode -Exception $_.Exception
            if ($attempt -eq 0 -and $statusCode -eq 401 -and
                $Server.Settings.OAuthManaged) {
                Clear-McpOAuthCredential -ServerName $Server.Name
                continue
            }
            throw
        }
    }
    if (-not $initializeResult) {
        throw "MCP server '$($Server.Name)' did not initialize."
    }
    $protocolVersion = [string](Get-PropertyValue `
        -Object $initializeResult -Name 'protocolVersion' -Default '')
    if ($protocolVersion -notin @('2025-03-26', '2025-06-18')) {
        throw "MCP server '$($Server.Name)' negotiated unsupported protocol " +
            "'$protocolVersion'."
    }
    $capabilities = Get-PropertyValue -Object $initializeResult -Name 'capabilities'
    if (-not $capabilities) {
        throw "MCP server '$($Server.Name)' omitted capabilities during initialization."
    }
    if ($null -eq $capabilities.PSObject.Properties['tools']) {
        throw "MCP server '$($Server.Name)' does not advertise the tools capability."
    }
    $serverInfo = Get-PropertyValue -Object $initializeResult -Name 'serverInfo'
    if (-not $serverInfo) {
        throw "MCP server '$($Server.Name)' omitted serverInfo during initialization."
    }

    $Server.ProtocolVersion = $protocolVersion
    $Server.Capabilities = $capabilities
    $Server.ServerInfo = $serverInfo
    Send-McpNotification -Server $Server -Method 'notifications/initialized'
}

function Get-McpServerTools {
    param([pscustomobject] $Server)

    $tools = [System.Collections.Generic.List[object]]::new()
    $cursor = ''
    for ($page = 0; $page -lt 100; $page++) {
        $params = @{}
        if ($cursor) {
            $params.cursor = $cursor
        }
        $result = Invoke-McpRequest -Server $Server -Method 'tools/list' -Params $params
        foreach ($tool in @(Get-PropertyValue -Object $result -Name 'tools' -Default @())) {
            $tools.Add($tool)
        }
        $cursor = [string](Get-PropertyValue -Object $result -Name 'nextCursor' -Default '')
        if (-not $cursor) {
            return $tools.ToArray()
        }
    }
    throw "MCP server '$($Server.Name)' exceeded 100 pages while listing tools."
}

function Invoke-McpServerTool {
    param(
        [pscustomobject] $Server,
        [string] $ToolName,
        [object] $Arguments
    )

    $argumentMap = @{}
    if ($Arguments) {
        foreach ($property in $Arguments.PSObject.Properties) {
            $argumentMap[$property.Name] = $property.Value
        }
    }
    return Invoke-McpRequest -Server $Server -Method 'tools/call' -Params @{
        name      = $ToolName
        arguments = $argumentMap
    }
}

function Close-McpServerTransport {
    param([pscustomobject] $Server)

    if (-not $Server.Client) {
        return
    }

    $request = $null
    $response = $null
    try {
        if (-not $Server.SessionId -or -not $Server.Settings) {
            return
        }
        $request = [System.Net.Http.HttpRequestMessage]::new(
            [System.Net.Http.HttpMethod]::Delete,
            $Server.Settings.Uri
        )
        foreach ($entry in $Server.Settings.Headers.GetEnumerator()) {
            $null = $request.Headers.TryAddWithoutValidation(
                [string]$entry.Key,
                [string]$entry.Value
            )
        }
        $null = $request.Headers.TryAddWithoutValidation(
            'MCP-Protocol-Version',
            $Server.ProtocolVersion
        )
        $null = $request.Headers.TryAddWithoutValidation(
            'Mcp-Session-Id',
            $Server.SessionId
        )
        $response = $Server.Client.SendAsync($request).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode -and
            [int]$response.StatusCode -notin @(401, 404, 405)) {
            throw "MCP server '$($Server.Name)' rejected session shutdown with HTTP " +
                "$([int]$response.StatusCode)."
        }
    }
    finally {
        if ($response) {
            $response.Dispose()
        }
        if ($request) {
            $request.Dispose()
        }
        $Server.Client.Dispose()
        $Server.Client = $null
    }
}
