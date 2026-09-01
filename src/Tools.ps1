function Get-ToolDefinitions {
    param(
        [ValidateSet('build', 'plan')]
        [string] $Mode
    )

    $tools = @(
        @{
            type = 'function'
            function = @{
                name        = 'list_files'
                description = 'List files. Paths may be workspace-relative or absolute when enabled.'
                parameters  = @{
                    type       = 'object'
                    properties = @{
                        path    = @{ type = 'string'; description = 'Directory, default "."' }
                        pattern = @{ type = 'string'; description = 'PowerShell wildcard, default "*"' }
                        recurse = @{ type = 'boolean'; description = 'Whether to recurse' }
                    }
                }
            }
        },
        @{
            type = 'function'
            function = @{
                name        = 'read_file'
                description = 'Read a UTF-8 text file from an allowed path.'
                parameters  = @{
                    type       = 'object'
                    required   = @('path')
                    properties = @{
                        path       = @{ type = 'string' }
                        start_line = @{ type = 'integer'; minimum = 1 }
                        line_count = @{ type = 'integer'; minimum = 1; maximum = 2000 }
                    }
                }
            }
        },
        @{
            type = 'function'
            function = @{
                name        = 'search_text'
                description = 'Search text files in an allowed path using a .NET regular expression.'
                parameters  = @{
                    type       = 'object'
                    required   = @('pattern')
                    properties = @{
                        pattern   = @{ type = 'string' }
                        path      = @{ type = 'string'; description = 'Directory, default "."' }
                        file_glob = @{ type = 'string'; description = 'PowerShell wildcard, default "*"' }
                    }
                }
            }
        },
        @{
            type = 'function'
            function = @{
                name        = 'write_file'
                description = 'Create or overwrite a UTF-8 text file at an allowed path.'
                parameters  = @{
                    type       = 'object'
                    required   = @('path', 'content')
                    properties = @{
                        path    = @{ type = 'string' }
                        content = @{ type = 'string' }
                    }
                }
            }
        },
        @{
            type = 'function'
            function = @{
                name        = 'replace_text'
                description = 'Replace one exact, unique text occurrence in a workspace file.'
                parameters  = @{
                    type       = 'object'
                    required   = @('path', 'old_text', 'new_text')
                    properties = @{
                        path     = @{ type = 'string' }
                        old_text = @{ type = 'string' }
                        new_text = @{ type = 'string' }
                    }
                }
            }
        },
        @{
            type = 'function'
            function = @{
                name        = 'run_powershell'
                description = 'Run a PowerShell command in the workspace.'
                parameters  = @{
                    type       = 'object'
                    required   = @('command')
                    properties = @{
                        command = @{ type = 'string' }
                    }
                }
            }
        }
    )

    if ($Mode -eq 'plan') {
        return @($tools | Where-Object {
            $_.function.name -in @('list_files', 'read_file', 'search_text', 'run_powershell')
        })
    }
    return $tools
}

function Resolve-WorkspacePath {
    param(
        [string] $Root,
        [string] $Path,
        [switch] $MustExist,
        [switch] $AllowOutsideWorkspace
    )

    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) {
        [System.IO.Path]::GetFullPath($Path)
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path $Root $Path))
    }

    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $prefix = "$rootPath$([System.IO.Path]::DirectorySeparatorChar)"
    if (-not $AllowOutsideWorkspace -and $candidate -ne $rootPath -and
        -not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the workspace: $Path"
    }
    if ($MustExist -and -not (Test-Path -LiteralPath $candidate)) {
        throw "Path does not exist: $Path"
    }

    if (Test-Path -LiteralPath $candidate) {
        $resolved = (Resolve-Path -LiteralPath $candidate).Path
        if (-not $AllowOutsideWorkspace -and $resolved -ne $rootPath -and
            -not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Resolved path is outside the workspace: $Path"
        }
        return $resolved
    }
    return $candidate
}

function Confirm-ToolCall {
    param(
        [string] $Name,
        [object] $Arguments,
        [bool] $ApproveAutomatically,
        [ValidateSet('build', 'plan')]
        [string] $Mode
    )

    if ($Mode -eq 'plan' -and $Name -in @('write_file', 'replace_text')) {
        return $false
    }
    if ($Name -in @('list_files', 'read_file', 'search_text')) {
        return $true
    }
    if ($Mode -eq 'build' -and $ApproveAutomatically) {
        return $true
    }
    if ([Console]::IsInputRedirected) {
        return $false
    }

    Write-Host ''
    Write-Host "Permission requested: $Name" -ForegroundColor Yellow
    Write-Host ($Arguments | ConvertTo-Json -Depth 20)
    return (Read-Host 'Allow once? [y/N]') -match '^(y|yes)$'
}

function Invoke-AgentTool {
    param(
        [string] $Name,
        [object] $Arguments,
        [string] $Root,
        [ValidateSet('build', 'plan')]
        [string] $Mode,
        [switch] $AllowOutsideWorkspace
    )

    if ($Mode -eq 'plan' -and $Name -in @('write_file', 'replace_text')) {
        throw "Tool '$Name' is unavailable in plan mode."
    }

    switch ($Name) {
        'list_files' {
            $path = Resolve-WorkspacePath -Root $Root `
                -Path (Get-PropertyValue -Object $Arguments -Name 'path' -Default '.') `
                -MustExist -AllowOutsideWorkspace:$AllowOutsideWorkspace
            $pattern = Get-PropertyValue -Object $Arguments -Name 'pattern' -Default '*'
            $recurse = [bool](Get-PropertyValue -Object $Arguments -Name 'recurse' -Default $false)
            $items = Get-ChildItem -LiteralPath $path -Filter $pattern -File -Recurse:$recurse |
                Select-Object -First 1000
            return (($items | ForEach-Object {
                [System.IO.Path]::GetRelativePath($Root, $_.FullName)
            }) -join "`n")
        }
        'read_file' {
            $path = Resolve-WorkspacePath -Root $Root -Path $Arguments.path -MustExist `
                -AllowOutsideWorkspace:$AllowOutsideWorkspace
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Not a file: $($Arguments.path)"
            }
            $lines = [System.IO.File]::ReadAllLines($path)
            $start = [Math]::Max(
                [int](Get-PropertyValue -Object $Arguments -Name 'start_line' -Default 1),
                1
            )
            $count = [Math]::Min(
                [int](Get-PropertyValue -Object $Arguments -Name 'line_count' -Default 400),
                2000
            )
            $end = [Math]::Min($start - 1 + $count, $lines.Length)
            if ($start -gt $lines.Length) {
                return ''
            }
            return (($start - 1)..($end - 1) | ForEach-Object {
                "$($_ + 1). $($lines[$_])"
            }) -join "`n"
        }
        'search_text' {
            $path = Resolve-WorkspacePath -Root $Root `
                -Path (Get-PropertyValue -Object $Arguments -Name 'path' -Default '.') `
                -MustExist -AllowOutsideWorkspace:$AllowOutsideWorkspace
            $glob = Get-PropertyValue -Object $Arguments -Name 'file_glob' -Default '*'
            $regex = [regex]::new([string]$Arguments.pattern)
            $matches = [System.Collections.Generic.List[string]]::new()
            foreach ($file in (Get-ChildItem -LiteralPath $path -Filter $glob -File -Recurse)) {
                if ($file.Length -gt 1MB) {
                    continue
                }
                $lineNumber = 0
                foreach ($line in [System.IO.File]::ReadLines($file.FullName)) {
                    $lineNumber++
                    if ($regex.IsMatch($line)) {
                        $relative = [System.IO.Path]::GetRelativePath($Root, $file.FullName)
                        $matches.Add("$relative`:$lineNumber`:$line")
                        if ($matches.Count -ge 500) {
                            return $matches -join "`n"
                        }
                    }
                }
            }
            return $matches -join "`n"
        }
        'write_file' {
            $path = Resolve-WorkspacePath -Root $Root -Path $Arguments.path `
                -AllowOutsideWorkspace:$AllowOutsideWorkspace
            [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $path))
            [System.IO.File]::WriteAllText(
                $path,
                [string]$Arguments.content,
                [System.Text.UTF8Encoding]::new($false)
            )
            return "Wrote $([System.IO.Path]::GetRelativePath($Root, $path))."
        }
        'replace_text' {
            $path = Resolve-WorkspacePath -Root $Root -Path $Arguments.path -MustExist `
                -AllowOutsideWorkspace:$AllowOutsideWorkspace
            $content = [System.IO.File]::ReadAllText($path)
            $oldText = [string]$Arguments.old_text
            $first = $content.IndexOf($oldText, [StringComparison]::Ordinal)
            if ($first -lt 0) {
                throw 'old_text was not found.'
            }
            if ($content.IndexOf($oldText, $first + $oldText.Length, [StringComparison]::Ordinal) -ge 0) {
                throw 'old_text is not unique; provide more surrounding text.'
            }
            $updated = $content.Substring(0, $first) + [string]$Arguments.new_text +
                $content.Substring($first + $oldText.Length)
            [System.IO.File]::WriteAllText(
                $path,
                $updated,
                [System.Text.UTF8Encoding]::new($false)
            )
            return "Updated $([System.IO.Path]::GetRelativePath($Root, $path))."
        }
        'run_powershell' {
            $previousLocation = Get-Location
            try {
                Set-Location -LiteralPath $Root
                $scriptBlock = [scriptblock]::Create([string]$Arguments.command)
                try {
                    $output = & $scriptBlock 2>&1 | Out-String
                    return $output.TrimEnd()
                }
                catch {
                    $details = ($_ | Out-String).TrimEnd()
                    return "PowerShell command failed:`n$details"
                }
            }
            finally {
                Set-Location -LiteralPath $previousLocation
            }
        }
        default {
            throw "Unknown tool: $Name"
        }
    }
}
