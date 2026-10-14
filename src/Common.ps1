function Get-PropertyValue {
    param(
        [object] $Object,
        [string] $Name,
        [object] $Default = $null
    )

    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) {
        return $Object.$Name
    }
    return $Default
}

function Get-TransientTransportException {
    param([System.Exception] $Exception)

    $current = $Exception
    while ($current) {
        if ($current -is [System.Net.Http.HttpRequestException] -or
            $current -is [System.IO.IOException] -or
            $current -is [System.Net.Sockets.SocketException] -or
            $current -is [System.Threading.Tasks.TaskCanceledException]) {
            return $current
        }
        $current = $current.InnerException
    }
    return $null
}

function Invoke-JsonRequest {
    param(
        [ValidateSet('Get', 'Post')]
        [string] $Method,
        [string] $Uri,
        [hashtable] $Headers = @{},
        [object] $Body,
        [string] $Operation = 'Request',
        [string] $ContentType = 'application/json'
    )

    $client = [System.Net.Http.HttpClient]::new()
    $request = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::$Method,
        $Uri
    )
    try {
        foreach ($entry in $Headers.GetEnumerator()) {
            if (-not $request.Headers.TryAddWithoutValidation(
                [string]$entry.Key,
                [string]$entry.Value
            )) {
                throw "Invalid HTTP header: $($entry.Key)"
            }
        }

        if ($PSBoundParameters.ContainsKey('Body')) {
            $text = if ($ContentType -eq 'application/json') {
                $Body | ConvertTo-Json -Compress -Depth 100
            }
            elseif ($ContentType -eq 'application/x-www-form-urlencoded') {
                ($Body.GetEnumerator() | ForEach-Object {
                    '{0}={1}' -f
                        [System.Net.WebUtility]::UrlEncode([string]$_.Key),
                        [System.Net.WebUtility]::UrlEncode([string]$_.Value)
                }) -join '&'
            }
            else {
                [string]$Body
            }
            $request.Content = [System.Net.Http.StringContent]::new(
                $text,
                [System.Text.UTF8Encoding]::new($false),
                $ContentType
            )
        }

        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        try {
            $responseBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if (-not $response.IsSuccessStatusCode) {
                throw "$Operation failed with HTTP $([int]$response.StatusCode)`: $responseBody"
            }
            if (-not $responseBody) {
                return $null
            }
            return $responseBody | ConvertFrom-Json -Depth 100
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

function Get-SecretProtectionMethod {
    if ($IsWindows) {
        return 'dpapi'
    }
    return 'none'
}

function Protect-StoredSecret {
    param([string] $Value)

    if (-not $Value) {
        return ''
    }
    if ($IsWindows) {
        $secureValue = ConvertTo-SecureString -String $Value -AsPlainText -Force
        return ConvertFrom-SecureString -SecureString $secureValue
    }
    return $Value
}

function Unprotect-StoredSecret {
    param(
        [string] $Value,
        [string] $Protection = 'dpapi'
    )

    if (-not $Value) {
        return ''
    }
    if (-not $Protection) {
        $Protection = 'dpapi'
    }
    switch ($Protection) {
        'dpapi' {
            if (-not $IsWindows) {
                throw 'This credential was encrypted with Windows DPAPI and cannot be ' +
                    'read on this platform. Sign in again to re-create it on this machine.'
            }
            $secureValue = ConvertTo-SecureString -String $Value
            return [System.Net.NetworkCredential]::new('', $secureValue).Password
        }
        'none' {
            return $Value
        }
        default {
            throw "Unknown credential protection method '$Protection'."
        }
    }
}

function Set-UnixFilePermission {
    param(
        [string] $Path,
        [ValidateSet('OwnerFile', 'OwnerDirectory')]
        [string] $Scope
    )

    if ($IsWindows -or -not ('System.IO.UnixFileMode' -as [type])) {
        return
    }
    $mode = if ($Scope -eq 'OwnerDirectory') {
        [System.IO.UnixFileMode]'UserRead, UserWrite, UserExecute'
    }
    else {
        [System.IO.UnixFileMode]'UserRead, UserWrite'
    }
    [System.IO.File]::SetUnixFileMode($Path, $mode)
}

function New-PsOpenCodeDirectory {
    param([string] $Path)

    $directory = [System.IO.Directory]::CreateDirectory($Path)
    Set-UnixFilePermission -Path $directory.FullName -Scope OwnerDirectory
    return $directory.FullName
}

function Write-SecureJsonFile {
    param(
        [string] $Path,
        [object] $Document
    )

    $null = New-PsOpenCodeDirectory -Path (Split-Path -Parent $Path)
    # Create the file empty and restrict it before writing so the secret is never
    # momentarily readable by other users on non-Windows hosts.
    [System.IO.File]::Create($Path).Dispose()
    Set-UnixFilePermission -Path $Path -Scope OwnerFile
    [System.IO.File]::WriteAllText(
        $Path,
        ($Document | ConvertTo-Json),
        [System.Text.UTF8Encoding]::new($false)
    )
}
