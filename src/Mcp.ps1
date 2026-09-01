function Import-McpConfiguration {
    param([string] $Path)

    $state = [pscustomobject]@{
        ConfigPath = $Path
        Servers    = @{}
        ToolMap    = @{}
    }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $state
    }

    try {
        $document = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path)) |
            ConvertFrom-Json -Depth 100
    }
    catch {
        throw "Unable to read MCP configuration '$Path': $($_.Exception.Message)"
    }
    $configuredServers = Get-PropertyValue -Object $document -Name 'servers'
    if (-not $configuredServers) {
        throw "MCP configuration '$Path' must contain a 'servers' object."
    }

    foreach ($property in $configuredServers.PSObject.Properties) {
        if ($property.Name -notmatch '^[a-zA-Z0-9_-]+$') {
            throw "Invalid MCP server name '$($property.Name)'."
        }
        $state.Servers[$property.Name] = [pscustomobject]@{
            Name            = $property.Name
            Config          = $property.Value
            Settings        = $null
            Client          = $null
            SessionId       = ''
            ProtocolVersion = ''
            ServerInfo      = $null
            Capabilities    = $null
            NextRequestId   = 1
            Connected       = $false
            Selected        = $false
            Tools           = @()
            LastError       = ''
        }
    }
    return $state
}

function ConvertTo-McpFunctionName {
    param(
        [string] $ServerName,
        [string] $ToolName,
        [hashtable] $ExistingNames
    )

    $baseName = "mcp__${ServerName}__${ToolName}" -replace '[^a-zA-Z0-9_-]', '_'
    $hashBytes = [System.Security.Cryptography.SHA256]::HashData(
        [System.Text.Encoding]::UTF8.GetBytes("$ServerName`:$ToolName")
    )
    $hash = ([Convert]::ToHexString($hashBytes)).Substring(0, 10).ToLowerInvariant()
    $candidate = if ($baseName.Length -le 64) {
        $baseName
    }
    else {
        "$($baseName.Substring(0, 53))_$hash"
    }
    if ($ExistingNames.ContainsKey($candidate)) {
        $candidate = "$($candidate.Substring(0, [Math]::Min(53, $candidate.Length)))_$hash"
    }
    return $candidate
}

function Enable-McpServer {
    param(
        [pscustomobject] $State,
        [string] $Name
    )

    if (-not $State.Servers.ContainsKey($Name)) {
        throw "Unknown MCP server '$Name'."
    }
    $server = $State.Servers[$Name]
    if ($server.Connected) {
        $server.Selected = $true
        return
    }

    $mappings = [System.Collections.Generic.List[object]]::new()
    try {
        Connect-McpServerTransport -Server $server
        $remoteTools = @(Get-McpServerTools -Server $server)
        foreach ($tool in $remoteTools) {
            $originalName = [string](Get-PropertyValue -Object $tool -Name 'name')
            if (-not $originalName) {
                throw "MCP server '$Name' returned a tool without a name."
            }
            $exposedName = ConvertTo-McpFunctionName -ServerName $Name `
                -ToolName $originalName -ExistingNames $State.ToolMap
            $annotations = Get-PropertyValue -Object $tool -Name 'annotations'
            $readOnlyValue = Get-PropertyValue -Object $annotations -Name 'readOnlyHint'
            $mapping = [pscustomobject]@{
                ExposedName  = $exposedName
                OriginalName = $originalName
                ServerName   = $Name
                Server       = $server
                Tool         = $tool
                ReadOnly     = $readOnlyValue -is [bool] -and $readOnlyValue
            }
            $mappings.Add($mapping)
            $State.ToolMap[$exposedName] = $mapping
        }
        $server.Tools = $mappings.ToArray()
        $server.Connected = $true
        $server.Selected = $true
        $server.LastError = ''
    }
    catch {
        foreach ($mapping in @($mappings)) {
            [void]$State.ToolMap.Remove($mapping.ExposedName)
        }
        $server.Tools = @()
        $server.Connected = $false
        $server.Selected = $false
        $server.LastError = $_.Exception.Message
        try {
            Close-McpServerTransport -Server $server
        }
        catch {
            Write-Warning $_.Exception.Message
        }
        $server.SessionId = ''
        $server.ProtocolVersion = ''
        $server.Capabilities = $null
        throw
    }
}

function Disable-McpServer {
    param(
        [pscustomobject] $State,
        [string] $Name
    )

    if (-not $State.Servers.ContainsKey($Name)) {
        throw "Unknown MCP server '$Name'."
    }
    $server = $State.Servers[$Name]
    foreach ($mapping in @($server.Tools)) {
        [void]$State.ToolMap.Remove($mapping.ExposedName)
    }
    try {
        Close-McpServerTransport -Server $server
    }
    finally {
        $server.Tools = @()
        $server.Connected = $false
        $server.Selected = $false
        $server.SessionId = ''
        $server.ProtocolVersion = ''
        $server.Capabilities = $null
        $server.ServerInfo = $null
        $server.NextRequestId = 1
    }
}

function Get-McpToolDefinitions {
    param(
        [pscustomobject] $State,
        [ValidateSet('build', 'plan')]
        [string] $Mode
    )

    if (-not $State) {
        return @()
    }
    return @(
        $State.ToolMap.Values |
            Where-Object {
                $_.Server.Selected -and ($Mode -eq 'build' -or $_.ReadOnly)
            } |
            Sort-Object ExposedName |
            ForEach-Object {
                $description = [string](Get-PropertyValue `
                    -Object $_.Tool -Name 'description' -Default $_.OriginalName)
                $inputSchema = Get-PropertyValue -Object $_.Tool -Name 'inputSchema'
                if (-not $inputSchema) {
                    $inputSchema = @{ type = 'object'; properties = @{} }
                }
                @{
                    type     = 'function'
                    function = @{
                        name        = $_.ExposedName
                        description = "[$($_.ServerName) MCP] $description"
                        parameters  = $inputSchema
                    }
                }
            }
    )
}

function Test-McpTool {
    param(
        [pscustomobject] $State,
        [string] $Name
    )

    return $null -ne $State -and $State.ToolMap.ContainsKey($Name)
}

function Convert-McpToolResultToText {
    param(
        [object] $Result,
        [string] $ServerName,
        [string] $ToolName
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @(Get-PropertyValue -Object $Result -Name 'content' -Default @())) {
        if ($item -is [string]) {
            $parts.Add($item)
            continue
        }
        $type = [string](Get-PropertyValue -Object $item -Name 'type' -Default '')
        switch ($type) {
            'text' {
                $parts.Add([string](Get-PropertyValue -Object $item -Name 'text' -Default ''))
            }
            'image' {
                $mimeType = Get-PropertyValue -Object $item -Name 'mimeType' `
                    -Default 'unknown'
                $parts.Add("[Image result omitted: $mimeType]")
            }
            'audio' {
                $mimeType = Get-PropertyValue -Object $item -Name 'mimeType' `
                    -Default 'unknown'
                $parts.Add("[Audio result omitted: $mimeType]")
            }
            'resource' {
                $resource = Get-PropertyValue -Object $item -Name 'resource'
                $text = [string](Get-PropertyValue -Object $resource -Name 'text' -Default '')
                if ($text) {
                    $parts.Add($text)
                }
                else {
                    $uri = Get-PropertyValue -Object $resource -Name 'uri' -Default 'unknown'
                    $parts.Add("[Binary resource omitted: $uri]")
                }
            }
            default {
                $parts.Add(($item | ConvertTo-Json -Compress -Depth 30))
            }
        }
    }

    if ($parts.Count -eq 0) {
        $structured = Get-PropertyValue -Object $Result -Name 'structuredContent'
        if ($null -ne $structured) {
            $parts.Add(($structured | ConvertTo-Json -Depth 30))
        }
    }
    $text = $parts -join "`n"
    if ($text.Length -gt 100000) {
        $text = $text.Substring(0, 100000) +
            "`n[Result truncated by PSOpenCode at 100000 characters.]"
    }

    if ([bool](Get-PropertyValue -Object $Result -Name 'isError' -Default $false)) {
        throw "MCP tool '$ServerName/$ToolName' reported an error: $text"
    }
    return $text
}

function Invoke-McpTool {
    param(
        [pscustomobject] $State,
        [string] $Name,
        [object] $Arguments,
        [ValidateSet('build', 'plan')]
        [string] $Mode
    )

    if (-not (Test-McpTool -State $State -Name $Name)) {
        throw "Unknown MCP tool '$Name'."
    }
    $mapping = $State.ToolMap[$Name]
    if (-not $mapping.Server.Selected) {
        throw "MCP server '$($mapping.ServerName)' is not selected for this session."
    }
    if ($Mode -eq 'plan' -and -not $mapping.ReadOnly) {
        throw "MCP tool '$($mapping.ServerName)/$($mapping.OriginalName)' is not read-only."
    }

    try {
        $result = Invoke-McpServerTool -Server $mapping.Server `
            -ToolName $mapping.OriginalName -Arguments $Arguments
    }
    catch {
        $statusCode = Get-McpExceptionStatusCode -Exception $_.Exception
        if ($statusCode -ne 404 -or -not $mapping.Server.SessionId) {
            throw
        }

        $serverName = $mapping.ServerName
        $originalName = $mapping.OriginalName
        Disable-McpServer -State $State -Name $serverName
        Enable-McpServer -State $State -Name $serverName
        $mapping = $State.ToolMap.Values |
            Where-Object {
                $_.ServerName -eq $serverName -and $_.OriginalName -eq $originalName
            } |
            Select-Object -First 1
        if (-not $mapping) {
            throw "MCP tool '$serverName/$originalName' disappeared after reconnecting."
        }
        if ($Mode -eq 'plan' -and -not $mapping.ReadOnly) {
            throw "MCP tool '$serverName/$originalName' is no longer read-only."
        }
        $result = Invoke-McpServerTool -Server $mapping.Server `
            -ToolName $mapping.OriginalName -Arguments $Arguments
    }
    return Convert-McpToolResultToText -Result $result `
        -ServerName $mapping.ServerName -ToolName $mapping.OriginalName
}

function Show-McpServers {
    param([pscustomobject] $State)

    if (-not $State -or $State.Servers.Count -eq 0) {
        $configPath = if ($State) { $State.ConfigPath } else { '(none)' }
        Write-Host "No MCP servers are configured in '$configPath'."
        return
    }
    $State.Servers.Values |
        Sort-Object Name |
        Select-Object Name, @{
            Name = 'Status'
            Expression = {
                if ($_.Selected -and $_.Connected) { 'selected' }
                elseif ($_.LastError) { 'error' }
                else { 'off' }
            }
        }, @{
            Name = 'Tools'
            Expression = { @($_.Tools).Count }
        }, @{
            Name = 'Details'
            Expression = { $_.LastError }
        } |
        Format-Table -AutoSize -Wrap
}

function Get-McpSelectionLabel {
    param([pscustomobject] $State)

    if (-not $State) {
        return 'none'
    }
    $names = @(
        $State.Servers.Values |
            Where-Object { $_.Selected -and $_.Connected } |
            Sort-Object Name |
            ForEach-Object Name
    )
    if ($names.Count -eq 0) {
        return 'none'
    }
    return $names -join ','
}

function Close-McpConnections {
    param([pscustomobject] $State)

    if (-not $State) {
        return
    }
    foreach ($server in @($State.Servers.Values | Where-Object Connected)) {
        try {
            Disable-McpServer -State $State -Name $server.Name
        }
        catch {
            Write-Warning $_.Exception.Message
        }
    }
}
