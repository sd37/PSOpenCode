function Get-McpLocalSettingsPath {
    return Join-Path (Join-Path $HOME '.psopencode') 'mcp-settings.json'
}

function Get-McpLocalSetting {
    param([string] $Name)

    $path = Get-McpLocalSettingsPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return ''
    }
    try {
        $document = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -Depth 20
        return [string](Get-PropertyValue -Object $document -Name $Name -Default '')
    }
    catch {
        throw "Unable to read MCP settings '$path': $($_.Exception.Message)"
    }
}

function Save-McpLocalSetting {
    param(
        [string] $Name,
        [string] $Value
    )

    $path = Get-McpLocalSettingsPath
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    $settings = [ordered]@{}
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $document = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -Depth 20
        foreach ($property in $document.PSObject.Properties) {
            $settings[$property.Name] = [string]$property.Value
        }
    }
    $settings[$Name] = $Value
    [System.IO.File]::WriteAllText(
        $path,
        ($settings | ConvertTo-Json),
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Get-McpOAuthCredentialPath {
    param([string] $ServerName)

    $safeName = $ServerName -replace '[^a-zA-Z0-9._-]', '_'
    return Join-Path (Join-Path $HOME '.psopencode') "mcp-auth-$safeName.json"
}

function Protect-McpOAuthSecret {
    param([string] $Value)

    if (-not $Value) {
        return ''
    }
    if (-not $IsWindows) {
        throw 'MCP OAuth token persistence currently requires Windows DPAPI.'
    }
    $secureValue = ConvertTo-SecureString -String $Value -AsPlainText -Force
    return ConvertFrom-SecureString -SecureString $secureValue
}

function Unprotect-McpOAuthSecret {
    param([string] $Value)

    if (-not $Value) {
        return ''
    }
    if (-not $IsWindows) {
        throw 'Stored MCP OAuth tokens require Windows DPAPI.'
    }
    $secureValue = ConvertTo-SecureString -String $Value
    return [System.Net.NetworkCredential]::new('', $secureValue).Password
}

function Get-McpOAuthCredential {
    param([string] $ServerName)

    $path = Get-McpOAuthCredentialPath -ServerName $ServerName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    try {
        $document = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -Depth 20
        return [pscustomobject]@{
            Resource      = [string](Get-PropertyValue -Object $document -Name 'resource' -Default '')
            ClientId      = [string](Get-PropertyValue -Object $document -Name 'clientId' -Default '')
            ClientSecret  = Unprotect-McpOAuthSecret -Value (
                [string](Get-PropertyValue -Object $document -Name 'protectedClientSecret' -Default '')
            )
            AccessToken   = Unprotect-McpOAuthSecret -Value (
                [string](Get-PropertyValue -Object $document -Name 'protectedAccessToken' -Default '')
            )
            RefreshToken  = Unprotect-McpOAuthSecret -Value (
                [string](Get-PropertyValue -Object $document -Name 'protectedRefreshToken' -Default '')
            )
            ExpiresAt     = [string](Get-PropertyValue -Object $document -Name 'expiresAt' -Default '')
            Issuer        = [string](Get-PropertyValue -Object $document -Name 'issuer' -Default '')
            TokenEndpoint = [string](Get-PropertyValue -Object $document -Name 'tokenEndpoint' -Default '')
            Scope         = [string](Get-PropertyValue -Object $document -Name 'scope' -Default '')
        }
    }
    catch {
        throw "Unable to read OAuth credentials for MCP server '$ServerName': " +
            $_.Exception.Message
    }
}

function Save-McpOAuthCredential {
    param(
        [string] $ServerName,
        [string] $Resource,
        [string] $ClientId,
        [string] $ClientSecret,
        [string] $AccessToken,
        [string] $RefreshToken,
        [DateTimeOffset] $ExpiresAt,
        [string] $Issuer,
        [string] $TokenEndpoint,
        [string] $Scope
    )

    $path = Get-McpOAuthCredentialPath -ServerName $ServerName
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    $document = [ordered]@{
        resource              = $Resource
        clientId              = $ClientId
        protectedClientSecret = Protect-McpOAuthSecret -Value $ClientSecret
        protectedAccessToken  = Protect-McpOAuthSecret -Value $AccessToken
        protectedRefreshToken = Protect-McpOAuthSecret -Value $RefreshToken
        expiresAt             = $ExpiresAt.ToUniversalTime().ToString('O')
        issuer                = $Issuer
        tokenEndpoint         = $TokenEndpoint
        scope                 = $Scope
    }
    [System.IO.File]::WriteAllText(
        $path,
        ($document | ConvertTo-Json),
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Clear-McpOAuthCredential {
    param([string] $ServerName)

    $path = Get-McpOAuthCredentialPath -ServerName $ServerName
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Invoke-McpOAuthHttpRequest {
    param(
        [ValidateSet('Get', 'Post')]
        [string] $Method,
        [Uri] $Uri,
        [hashtable] $Headers = @{},
        [object] $Body,
        [string] $ContentType = 'application/json'
    )

    $client = [System.Net.Http.HttpClient]::new()
    $request = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::$Method,
        $Uri
    )
    try {
        foreach ($entry in $Headers.GetEnumerator()) {
            $null = $request.Headers.TryAddWithoutValidation(
                [string]$entry.Key,
                [string]$entry.Value
            )
        }
        if ($PSBoundParameters.ContainsKey('Body')) {
            $text = if ($ContentType -eq 'application/x-www-form-urlencoded') {
                ($Body.GetEnumerator() | ForEach-Object {
                    '{0}={1}' -f
                        [System.Net.WebUtility]::UrlEncode([string]$_.Key),
                        [System.Net.WebUtility]::UrlEncode([string]$_.Value)
                }) -join '&'
            }
            else {
                $Body | ConvertTo-Json -Compress -Depth 30
            }
            $request.Content = [System.Net.Http.StringContent]::new(
                $text,
                [System.Text.UTF8Encoding]::new($false),
                $ContentType
            )
        }
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        try {
            $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $data = $null
            if ($text) {
                try {
                    $data = $text | ConvertFrom-Json -Depth 100
                }
                catch {
                    $data = $null
                }
            }
            return [pscustomobject]@{
                StatusCode      = [int]$response.StatusCode
                IsSuccess       = $response.IsSuccessStatusCode
                Data            = $data
                Text            = $text
                WwwAuthenticate = @($response.Headers.WwwAuthenticate) -join ', '
            }
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

function Assert-McpOAuthUri {
    param(
        [string] $Value,
        [string] $Description,
        [Uri] $ResourceUri
    )

    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) {
        throw "MCP OAuth $Description is not an absolute URL."
    }
    if ($uri.Scheme -ne 'https' -and
        -not ($uri.Scheme -eq 'http' -and $uri.IsLoopback -and $ResourceUri.IsLoopback)) {
        throw "MCP OAuth $Description must use HTTPS."
    }
    return $uri
}

function Get-McpProtectedResourceMetadata {
    param(
        [pscustomobject] $Server,
        [Uri] $ResourceUri
    )

    $initialize = @{
        jsonrpc = '2.0'
        id      = 1
        method  = 'initialize'
        params  = @{
            protocolVersion = '2025-06-18'
            capabilities    = @{}
            clientInfo      = @{ name = 'PSOpenCode'; version = '1.0' }
        }
    }
    $challenge = Invoke-McpOAuthHttpRequest -Method Post -Uri $ResourceUri `
        -Headers @{ Accept = 'application/json, text/event-stream' } -Body $initialize
    if ($challenge.IsSuccess) {
        return $null
    }
    if ($challenge.StatusCode -ne 401) {
        throw "MCP server '$($Server.Name)' returned HTTP $($challenge.StatusCode) " +
            'while discovering OAuth.'
    }

    $metadataUrl = ''
    if ($challenge.WwwAuthenticate -match 'resource_metadata\s*=\s*"([^"]+)"') {
        $metadataUrl = $Matches[1]
    }
    if (-not $metadataUrl) {
        $suffix = $ResourceUri.AbsolutePath.Trim('/')
        $metadataUrl = $ResourceUri.GetLeftPart([UriPartial]::Authority) +
            '/.well-known/oauth-protected-resource'
        if ($suffix) {
            $metadataUrl += "/$suffix"
        }
    }
    $metadataUri = Assert-McpOAuthUri -Value $metadataUrl `
        -Description 'protected-resource metadata URL' -ResourceUri $ResourceUri
    $response = Invoke-McpOAuthHttpRequest -Method Get -Uri $metadataUri `
        -Headers @{ Accept = 'application/json' }
    if (-not $response.IsSuccess -or -not $response.Data) {
        throw "Unable to read OAuth protected-resource metadata for MCP server " +
            "'$($Server.Name)' (HTTP $($response.StatusCode))."
    }
    $declaredResource = [string](Get-PropertyValue `
        -Object $response.Data -Name 'resource' -Default '')
    if ($declaredResource -and
        $declaredResource.TrimEnd('/') -ne $ResourceUri.AbsoluteUri.TrimEnd('/')) {
        throw "MCP server '$($Server.Name)' returned OAuth metadata for a different resource."
    }
    return $response.Data
}

function Get-McpAuthorizationServerMetadata {
    param(
        [string] $AuthorizationServer,
        [Uri] $ResourceUri,
        [string] $ServerName
    )

    $serverUri = Assert-McpOAuthUri -Value $AuthorizationServer `
        -Description 'authorization-server URL' -ResourceUri $ResourceUri
    $authority = $serverUri.GetLeftPart([UriPartial]::Authority)
    $path = $serverUri.AbsolutePath.TrimEnd('/')
    $candidates = @(
        "$authority/.well-known/oauth-authorization-server$path",
        "$($serverUri.AbsoluteUri.TrimEnd('/'))/.well-known/openid-configuration"
    ) | Select-Object -Unique
    foreach ($candidate in $candidates) {
        $candidateUri = Assert-McpOAuthUri -Value $candidate `
            -Description 'authorization-server metadata URL' -ResourceUri $ResourceUri
        $response = Invoke-McpOAuthHttpRequest -Method Get -Uri $candidateUri `
            -Headers @{ Accept = 'application/json' }
        if ($response.IsSuccess -and $response.Data) {
            $issuer = [string](Get-PropertyValue `
                -Object $response.Data -Name 'issuer' -Default '')
            if ($issuer -and $issuer -notmatch '\{[^}]+\}') {
                $issuerUri = Assert-McpOAuthUri -Value $issuer `
                    -Description 'issuer URL' -ResourceUri $ResourceUri
                if ($issuerUri.GetLeftPart([UriPartial]::Authority) -ne
                    $serverUri.GetLeftPart([UriPartial]::Authority)) {
                    throw "MCP server '$ServerName' authorization metadata " +
                        'declares an issuer on a different authority.'
                }
            }
            return $response.Data
        }
    }
    throw "MCP server '$ServerName' uses an authorization server that does not " +
        'publish OAuth or OpenID Connect metadata.'
}

function Get-McpOAuthScopes {
    param(
        [object] $AuthConfig,
        [object] $ResourceMetadata,
        [string] $ServerName
    )

    $configured = @(
        Get-PropertyValue -Object $AuthConfig -Name 'scopes' -Default @() |
            ForEach-Object { [string]$_ } |
            Where-Object { $_ }
    )
    if ($configured.Count -gt 0) {
        return $configured
    }
    $advertised = @(
        Get-PropertyValue -Object $ResourceMetadata -Name 'scopes_supported' -Default @() |
            ForEach-Object { [string]$_ } |
            Where-Object { $_ }
    )
    if ($advertised.Count -eq 1) {
        return $advertised
    }
    throw "MCP server '$ServerName' requires explicit OAuth scopes in mcp.json."
}

function Register-McpOAuthClient {
    param(
        [Uri] $RegistrationEndpoint,
        [string] $ServerName
    )

    $response = Invoke-McpOAuthHttpRequest -Method Post -Uri $RegistrationEndpoint `
        -Headers @{ Accept = 'application/json' } -Body @{
            client_name                = 'PSOpenCode'
            grant_types               = @(
                'urn:ietf:params:oauth:grant-type:device_code',
                'refresh_token'
            )
            token_endpoint_auth_method = 'none'
        }
    if (-not $response.IsSuccess -or -not $response.Data) {
        throw "Dynamic OAuth client registration failed for MCP server '$ServerName' " +
            "(HTTP $($response.StatusCode))."
    }
    $clientId = [string](Get-PropertyValue -Object $response.Data -Name 'client_id' -Default '')
    if (-not $clientId) {
        throw "The OAuth registration response for MCP server '$ServerName' omitted client_id."
    }
    return [pscustomobject]@{
        ClientId     = $clientId
        ClientSecret = [string](Get-PropertyValue `
            -Object $response.Data -Name 'client_secret' -Default '')
    }
}

function Get-McpOAuthClient {
    param(
        [pscustomobject] $Server,
        [object] $AuthConfig,
        [object] $AuthorizationMetadata,
        [pscustomobject] $StoredCredential,
        [Uri] $ResourceUri
    )

    $configuredClientId = [string](Get-PropertyValue `
        -Object $AuthConfig -Name 'clientId' -Default '')
    if ($configuredClientId) {
        $configuredClientId = Resolve-McpTemplate -Value $configuredClientId `
            -ServerName $Server.Name -AllowPrompt
    }
    if (-not $configuredClientId -and $StoredCredential) {
        $configuredClientId = $StoredCredential.ClientId
    }
    $settingName = 'oauthClientId_' + ($Server.Name -replace '[^a-zA-Z0-9_]', '_')
    if (-not $configuredClientId) {
        $configuredClientId = Get-McpLocalSetting -Name $settingName
    }
    if ($configuredClientId) {
        return [pscustomobject]@{
            ClientId     = $configuredClientId
            ClientSecret = if ($StoredCredential -and
                $StoredCredential.ClientId -eq $configuredClientId) {
                $StoredCredential.ClientSecret
            }
            else {
                ''
            }
        }
    }

    $registrationUrl = [string](Get-PropertyValue `
        -Object $AuthorizationMetadata -Name 'registration_endpoint' -Default '')
    if ($registrationUrl) {
        $registrationUri = Assert-McpOAuthUri -Value $registrationUrl `
            -Description 'client-registration endpoint' -ResourceUri $ResourceUri
        return Register-McpOAuthClient -RegistrationEndpoint $registrationUri `
            -ServerName $Server.Name
    }

    Write-Host ''
    Write-Host (
        "MCP server '$($Server.Name)' requires a public OAuth client ID. " +
        'Its authorization server does not support dynamic registration.'
    ) -ForegroundColor Yellow
    $configuredClientId = (Read-Host 'OAuth client ID (not a secret)').Trim()
    if (-not $configuredClientId) {
        throw "OAuth client ID is required for MCP server '$($Server.Name)'."
    }
    Save-McpLocalSetting -Name $settingName -Value $configuredClientId
    return [pscustomobject]@{
        ClientId     = $configuredClientId
        ClientSecret = ''
    }
}

function Request-McpOAuthDeviceToken {
    param(
        [pscustomobject] $Server,
        [Uri] $ResourceUri,
        [Uri] $DeviceEndpoint,
        [Uri] $TokenEndpoint,
        [string] $ClientId,
        [string] $ClientSecret,
        [string[]] $Scopes
    )

    $scope = $Scopes -join ' '
    $deviceBody = @{
        client_id = $ClientId
        resource  = $ResourceUri.AbsoluteUri.TrimEnd('/')
        scope     = $scope
    }
    if ($ClientSecret) {
        $deviceBody.client_secret = $ClientSecret
    }
    $deviceResponse = Invoke-McpOAuthHttpRequest -Method Post -Uri $DeviceEndpoint `
        -Headers @{ Accept = 'application/json' } -Body $deviceBody `
        -ContentType 'application/x-www-form-urlencoded'
    $useResourceIndicator = $true
    if (-not $deviceResponse.IsSuccess -and
        (Get-PropertyValue -Object $deviceResponse.Data -Name 'error') -eq 'invalid_target') {
        $deviceBody.Remove('resource')
        $deviceResponse = Invoke-McpOAuthHttpRequest -Method Post -Uri $DeviceEndpoint `
            -Headers @{ Accept = 'application/json' } -Body $deviceBody `
            -ContentType 'application/x-www-form-urlencoded'
        $useResourceIndicator = $false
    }
    if (-not $deviceResponse.IsSuccess -or -not $deviceResponse.Data) {
        throw "Unable to start OAuth device login for MCP server '$($Server.Name)' " +
            "(HTTP $($deviceResponse.StatusCode))."
    }
    $device = $deviceResponse.Data
    $verificationUri = [string](Get-PropertyValue `
        -Object $device -Name 'verification_uri' -Default '')
    $verificationComplete = [string](Get-PropertyValue `
        -Object $device -Name 'verification_uri_complete' -Default '')
    $userCode = [string](Get-PropertyValue -Object $device -Name 'user_code' -Default '')
    $deviceCode = [string](Get-PropertyValue -Object $device -Name 'device_code' -Default '')
    if (-not $verificationUri -or -not $deviceCode) {
        throw "OAuth device login for MCP server '$($Server.Name)' returned incomplete data."
    }

    Write-Host ''
    Write-Host "Authorize MCP server '$($Server.Name)':" -ForegroundColor Cyan
    Write-Host $(if ($verificationComplete) { $verificationComplete } else { $verificationUri })
    if ($userCode) {
        Write-Host "Code: $userCode" -ForegroundColor Yellow
    }
    Write-Host 'Waiting for authorization...' -ForegroundColor DarkGray

    $interval = [Math]::Max(
        [int](Get-PropertyValue -Object $device -Name 'interval' -Default 5),
        5
    )
    $expiresIn = [int](Get-PropertyValue -Object $device -Name 'expires_in' -Default 900)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($expiresIn)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds $interval
        $tokenBody = @{
            client_id   = $ClientId
            device_code = $deviceCode
            grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
        }
        if ($useResourceIndicator) {
            $tokenBody.resource = $ResourceUri.AbsoluteUri.TrimEnd('/')
        }
        if ($ClientSecret) {
            $tokenBody.client_secret = $ClientSecret
        }
        $tokenResponse = Invoke-McpOAuthHttpRequest -Method Post -Uri $TokenEndpoint `
            -Headers @{ Accept = 'application/json' } -Body $tokenBody `
            -ContentType 'application/x-www-form-urlencoded'
        $tokenData = $tokenResponse.Data
        $accessToken = [string](Get-PropertyValue `
            -Object $tokenData -Name 'access_token' -Default '')
        if ($tokenResponse.IsSuccess -and $accessToken) {
            return $tokenData
        }
        $oauthError = [string](Get-PropertyValue -Object $tokenData -Name 'error' -Default '')
        switch ($oauthError) {
            'authorization_pending' { continue }
            'slow_down' {
                $interval += 5
                continue
            }
            'access_denied' {
                throw "OAuth login was denied for MCP server '$($Server.Name)'."
            }
            'expired_token' {
                throw "The OAuth device code expired for MCP server '$($Server.Name)'."
            }
            default {
                $description = [string](Get-PropertyValue `
                    -Object $tokenData -Name 'error_description' -Default $oauthError)
                throw "OAuth login failed for MCP server '$($Server.Name)': $description"
            }
        }
    }
    throw "The OAuth device code expired for MCP server '$($Server.Name)'."
}

function ConvertTo-McpBase64Url {
    param([byte[]] $Bytes)

    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-McpOAuthRandomValue {
    param([int] $ByteCount)

    $bytes = [byte[]]::new($ByteCount)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return ConvertTo-McpBase64Url -Bytes $bytes
}

function Request-McpOAuthAuthorizationCodeToken {
    param(
        [pscustomobject] $Server,
        [Uri] $ResourceUri,
        [Uri] $AuthorizationEndpoint,
        [Uri] $TokenEndpoint,
        [string] $ClientId,
        [string] $ClientSecret,
        [string[]] $Scopes,
        [bool] $UseResourceIndicator = $true
    )

    $state = New-McpOAuthRandomValue -ByteCount 32
    $codeVerifier = New-McpOAuthRandomValue -ByteCount 64
    $challengeBytes = [System.Security.Cryptography.SHA256]::HashData(
        [System.Text.Encoding]::ASCII.GetBytes($codeVerifier)
    )
    $codeChallenge = ConvertTo-McpBase64Url -Bytes $challengeBytes

    $listener = $null
    $redirectUri = ''
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        $candidate = [System.Net.HttpListener]::new()
        $port = Get-Random -Minimum 49152 -Maximum 65000
        $candidate.Prefixes.Add("http://localhost:$port/")
        try {
            $candidate.Start()
            $listener = $candidate
            $redirectUri = "http://localhost:$port/"
            break
        }
        catch [System.Net.HttpListenerException] {
            $candidate.Close()
        }
    }
    if (-not $listener) {
        throw "Unable to start the loopback OAuth callback for MCP server '$($Server.Name)'."
    }

    try {
        $parameters = [ordered]@{
            client_id             = $ClientId
            response_type         = 'code'
            redirect_uri          = $redirectUri
            response_mode         = 'query'
            scope                 = $Scopes -join ' '
            state                 = $state
            code_challenge        = $codeChallenge
            code_challenge_method = 'S256'
            prompt                = 'select_account'
        }
        if ($UseResourceIndicator) {
            $parameters.resource = $ResourceUri.AbsoluteUri.TrimEnd('/')
        }
        $query = ($parameters.GetEnumerator() | ForEach-Object {
            '{0}={1}' -f
                [System.Net.WebUtility]::UrlEncode([string]$_.Key),
                [System.Net.WebUtility]::UrlEncode([string]$_.Value)
        }) -join '&'
        $authorizationUrl = "$($AuthorizationEndpoint.AbsoluteUri)?$query"

        Write-Host ''
        Write-Host "Authorize MCP server '$($Server.Name)' in your browser:" `
            -ForegroundColor Cyan
        Write-Host $authorizationUrl
        Write-Host 'Waiting for the browser callback...' -ForegroundColor DarkGray

        $contextTask = $listener.GetContextAsync()
        if (-not $contextTask.Wait([TimeSpan]::FromMinutes(5))) {
            throw "OAuth login timed out for MCP server '$($Server.Name)'."
        }
        $context = $contextTask.GetAwaiter().GetResult()
        $queryValues = $context.Request.QueryString
        $oauthError = [string]$queryValues['error']
        $errorDescription = [string]$queryValues['error_description']
        $returnedState = [string]$queryValues['state']
        $authorizationCode = [string]$queryValues['code']

        $responseText = if ($oauthError) {
            'Authorization failed. Return to the terminal for details.'
        }
        else {
            'Authorization complete. You can close this window and return to PSOpenCode.'
        }
        $responseBytes = [System.Text.Encoding]::UTF8.GetBytes(
            "<!doctype html><html><body><p>$responseText</p></body></html>"
        )
        $context.Response.StatusCode = 200
        $context.Response.ContentType = 'text/html; charset=utf-8'
        $context.Response.ContentLength64 = $responseBytes.Length
        $context.Response.OutputStream.Write($responseBytes, 0, $responseBytes.Length)
        $context.Response.Close()

        if ($oauthError) {
            throw "OAuth login failed for MCP server '$($Server.Name)': " +
                ($errorDescription ?? $oauthError)
        }
        if (-not [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
            [System.Text.Encoding]::UTF8.GetBytes($state),
            [System.Text.Encoding]::UTF8.GetBytes($returnedState)
        )) {
            throw "OAuth login returned an invalid state for MCP server '$($Server.Name)'."
        }
        if (-not $authorizationCode) {
            throw "OAuth login returned no authorization code for MCP server '$($Server.Name)'."
        }

        $tokenBody = @{
            client_id     = $ClientId
            code          = $authorizationCode
            code_verifier = $codeVerifier
            grant_type    = 'authorization_code'
            redirect_uri  = $redirectUri
        }
        if ($ClientSecret) {
            $tokenBody.client_secret = $ClientSecret
        }
        if ($UseResourceIndicator) {
            $tokenBody.resource = $ResourceUri.AbsoluteUri.TrimEnd('/')
        }
        $tokenResponse = Invoke-McpOAuthHttpRequest -Method Post -Uri $TokenEndpoint `
            -Headers @{ Accept = 'application/json' } -Body $tokenBody `
            -ContentType 'application/x-www-form-urlencoded'
        $accessToken = [string](Get-PropertyValue `
            -Object $tokenResponse.Data -Name 'access_token' -Default '')
        if (-not $tokenResponse.IsSuccess -or -not $accessToken) {
            $tokenError = [string](Get-PropertyValue `
                -Object $tokenResponse.Data -Name 'error' -Default '')
            $tokenDescription = [string](Get-PropertyValue `
                -Object $tokenResponse.Data -Name 'error_description' -Default $tokenError)
            throw "OAuth token exchange failed for MCP server '$($Server.Name)': " +
                $tokenDescription
        }
        return $tokenResponse.Data
    }
    finally {
        if ($listener.IsListening) {
            $listener.Stop()
        }
        $listener.Close()
    }
}

function Refresh-McpOAuthToken {
    param(
        [pscustomobject] $Server,
        [pscustomobject] $Credential,
        [Uri] $ResourceUri,
        [Uri] $TokenEndpoint,
        [string[]] $Scopes,
        [bool] $UseResourceIndicator = $true
    )

    if (-not $Credential.RefreshToken) {
        return $null
    }
    $body = @{
        client_id     = $Credential.ClientId
        refresh_token = $Credential.RefreshToken
        grant_type    = 'refresh_token'
        scope         = $Scopes -join ' '
    }
    if ($UseResourceIndicator) {
        $body.resource = $ResourceUri.AbsoluteUri.TrimEnd('/')
    }
    if ($Credential.ClientSecret) {
        $body.client_secret = $Credential.ClientSecret
    }
    $response = Invoke-McpOAuthHttpRequest -Method Post -Uri $TokenEndpoint `
        -Headers @{ Accept = 'application/json' } -Body $body `
        -ContentType 'application/x-www-form-urlencoded'
    if (-not $response.IsSuccess -and
        (Get-PropertyValue -Object $response.Data -Name 'error') -eq 'invalid_target') {
        $body.Remove('resource')
        $response = Invoke-McpOAuthHttpRequest -Method Post -Uri $TokenEndpoint `
            -Headers @{ Accept = 'application/json' } -Body $body `
            -ContentType 'application/x-www-form-urlencoded'
    }
    if ($response.IsSuccess -and
        (Get-PropertyValue -Object $response.Data -Name 'access_token')) {
        return $response.Data
    }
    $oauthError = [string](Get-PropertyValue -Object $response.Data -Name 'error' -Default '')
    if ($oauthError -eq 'invalid_grant') {
        return $null
    }
    $description = [string](Get-PropertyValue `
        -Object $response.Data -Name 'error_description' -Default $oauthError)
    throw "Unable to refresh OAuth for MCP server '$($Server.Name)': $description"
}

function Save-McpOAuthTokenResponse {
    param(
        [pscustomobject] $Server,
        [Uri] $ResourceUri,
        [pscustomobject] $OAuthClient,
        [string] $Issuer,
        [Uri] $TokenEndpoint,
        [string[]] $Scopes,
        [object] $TokenResponse,
        [string] $ExistingRefreshToken = ''
    )

    $accessToken = [string](Get-PropertyValue `
        -Object $TokenResponse -Name 'access_token' -Default '')
    $tokenType = [string](Get-PropertyValue `
        -Object $TokenResponse -Name 'token_type' -Default 'Bearer')
    if (-not $accessToken -or $tokenType -ine 'Bearer') {
        throw "OAuth for MCP server '$($Server.Name)' did not return a bearer token."
    }
    $refreshToken = [string](Get-PropertyValue `
        -Object $TokenResponse -Name 'refresh_token' -Default $ExistingRefreshToken)
    $expiresIn = [Math]::Max(
        [int](Get-PropertyValue -Object $TokenResponse -Name 'expires_in' -Default 3600),
        60
    )
    $expiresAt = [DateTimeOffset]::UtcNow.AddSeconds($expiresIn)
    Save-McpOAuthCredential -ServerName $Server.Name `
        -Resource $ResourceUri.AbsoluteUri.TrimEnd('/') `
        -ClientId $OAuthClient.ClientId -ClientSecret $OAuthClient.ClientSecret `
        -AccessToken $accessToken -RefreshToken $refreshToken -ExpiresAt $expiresAt `
        -Issuer $Issuer `
        -TokenEndpoint $TokenEndpoint.AbsoluteUri -Scope ($Scopes -join ' ')
    return $accessToken
}

function Get-McpOAuthAccessToken {
    param(
        [pscustomobject] $Server,
        [Uri] $ResourceUri
    )

    $authConfig = Get-PropertyValue -Object $Server.Config -Name 'auth'
    if (-not $authConfig) {
        return ''
    }
    $authType = [string](Get-PropertyValue -Object $authConfig -Name 'type' -Default '')
    if ($authType -ne 'oauth') {
        throw "MCP server '$($Server.Name)' uses unsupported auth type '$authType'."
    }

    $resourceMetadata = Get-McpProtectedResourceMetadata `
        -Server $Server -ResourceUri $ResourceUri
    if (-not $resourceMetadata) {
        return ''
    }
    $configuredAuthorizationServer = [string](Get-PropertyValue `
        -Object $authConfig -Name 'authorizationServer' -Default '')
    $authorizationServers = if ($configuredAuthorizationServer) {
        @(
            Resolve-McpTemplate -Value $configuredAuthorizationServer `
                -ServerName $Server.Name -AllowPrompt
        )
    }
    else {
        @(
            Get-PropertyValue -Object $resourceMetadata `
                -Name 'authorization_servers' -Default @() |
                ForEach-Object { [string]$_ } |
                Where-Object { $_ }
        )
    }
    if ($authorizationServers.Count -eq 0) {
        throw "MCP server '$($Server.Name)' did not advertise an OAuth authorization server."
    }
    $authorizationMetadata = Get-McpAuthorizationServerMetadata `
        -AuthorizationServer $authorizationServers[0] -ResourceUri $ResourceUri `
        -ServerName $Server.Name
    $issuer = [string](Get-PropertyValue `
        -Object $authorizationMetadata -Name 'issuer' -Default $authorizationServers[0])
    $tokenUrl = [string](Get-PropertyValue `
        -Object $authorizationMetadata -Name 'token_endpoint' -Default '')
    $authorizationUrl = [string](Get-PropertyValue `
        -Object $authorizationMetadata -Name 'authorization_endpoint' -Default '')
    $deviceUrl = [string](Get-PropertyValue `
        -Object $authorizationMetadata -Name 'device_authorization_endpoint' -Default '')
    $flow = [string](Get-PropertyValue `
        -Object $authConfig -Name 'flow' -Default 'device_code')
    if ($flow -notin @('device_code', 'authorization_code')) {
        throw "MCP server '$($Server.Name)' uses unsupported OAuth flow '$flow'."
    }
    if (-not $tokenUrl -or ($flow -eq 'device_code' -and -not $deviceUrl) -or
        ($flow -eq 'authorization_code' -and -not $authorizationUrl)) {
        throw "MCP server '$($Server.Name)' authorization server does not support " +
            "the configured '$flow' OAuth flow."
    }
    $tokenEndpoint = Assert-McpOAuthUri -Value $tokenUrl `
        -Description 'token endpoint' -ResourceUri $ResourceUri
    $deviceEndpoint = if ($deviceUrl) {
        Assert-McpOAuthUri -Value $deviceUrl `
            -Description 'device-authorization endpoint' -ResourceUri $ResourceUri
    }
    else {
        $null
    }
    $authorizationEndpoint = if ($authorizationUrl) {
        Assert-McpOAuthUri -Value $authorizationUrl `
            -Description 'authorization endpoint' -ResourceUri $ResourceUri
    }
    else {
        $null
    }
    $scopes = @(Get-McpOAuthScopes -AuthConfig $authConfig `
        -ResourceMetadata $resourceMetadata -ServerName $Server.Name)
    $resourceIndicator = Get-PropertyValue `
        -Object $authConfig -Name 'useResourceIndicator' -Default $true
    if ($resourceIndicator -isnot [bool]) {
        throw "MCP server '$($Server.Name)' auth.useResourceIndicator must be a Boolean."
    }

    $credential = Get-McpOAuthCredential -ServerName $Server.Name
    $resource = $ResourceUri.AbsoluteUri.TrimEnd('/')
    if ($credential -and (
        $credential.Resource -ne $resource -or
        $credential.Issuer -ne $issuer -or
        $credential.TokenEndpoint -ne $tokenEndpoint.AbsoluteUri
    )) {
        $credential = $null
    }
    $oauthClient = Get-McpOAuthClient -Server $Server -AuthConfig $authConfig `
        -AuthorizationMetadata $authorizationMetadata -StoredCredential $credential `
        -ResourceUri $ResourceUri
    if ($credential -and $credential.ClientId -ne $oauthClient.ClientId) {
        $credential = $null
    }

    $requestedScope = ($scopes | Sort-Object -Unique) -join ' '
    $storedScope = if ($credential) {
        (($credential.Scope -split '\s+' | Where-Object { $_ }) |
            Sort-Object -Unique) -join ' '
    }
    else {
        ''
    }
    $tokenCredential = if ($credential -and $storedScope -eq $requestedScope) {
        $credential
    }
    else {
        $null
    }

    if ($tokenCredential -and $tokenCredential.AccessToken -and $tokenCredential.ExpiresAt) {
        $expiresAt = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse($tokenCredential.ExpiresAt, [ref]$expiresAt) -and
            $expiresAt -gt [DateTimeOffset]::UtcNow.AddMinutes(2)) {
            return $tokenCredential.AccessToken
        }
    }
    if ($tokenCredential) {
        $refreshed = Refresh-McpOAuthToken -Server $Server -Credential $tokenCredential `
            -ResourceUri $ResourceUri -TokenEndpoint $tokenEndpoint -Scopes $scopes `
            -UseResourceIndicator $resourceIndicator
        if ($refreshed) {
            return Save-McpOAuthTokenResponse -Server $Server -ResourceUri $ResourceUri `
                -OAuthClient $oauthClient -Issuer $issuer -TokenEndpoint $tokenEndpoint `
                -Scopes $scopes -TokenResponse $refreshed `
                -ExistingRefreshToken $tokenCredential.RefreshToken
        }
    }

    if ($flow -eq 'authorization_code') {
        $tokenResponse = Request-McpOAuthAuthorizationCodeToken -Server $Server `
            -ResourceUri $ResourceUri -AuthorizationEndpoint $authorizationEndpoint `
            -TokenEndpoint $tokenEndpoint -ClientId $oauthClient.ClientId `
            -ClientSecret $oauthClient.ClientSecret -Scopes $scopes `
            -UseResourceIndicator $resourceIndicator
    }
    else {
        $tokenResponse = Request-McpOAuthDeviceToken -Server $Server `
            -ResourceUri $ResourceUri -DeviceEndpoint $deviceEndpoint `
            -TokenEndpoint $tokenEndpoint -ClientId $oauthClient.ClientId `
            -ClientSecret $oauthClient.ClientSecret -Scopes $scopes
    }
    return Save-McpOAuthTokenResponse -Server $Server -ResourceUri $ResourceUri `
        -OAuthClient $oauthClient -Issuer $issuer -TokenEndpoint $tokenEndpoint `
        -Scopes $scopes -TokenResponse $tokenResponse
}
