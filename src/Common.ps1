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

function Test-IsWindowsPlatform {
    $isWindowsVariable = Get-Variable -Name IsWindows -ErrorAction SilentlyContinue
    if ($null -ne $isWindowsVariable) {
        return [bool]$isWindowsVariable.Value
    }
    return $env:OS -eq 'Windows_NT'
}

$script:ConvertFromJsonSupportsDepth = (Get-Command ConvertFrom-Json).Parameters.ContainsKey('Depth')

function ConvertFrom-JsonText {
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()]
        [string] $Json,
        [int] $Depth = 100
    )

    process {
        if ($script:ConvertFromJsonSupportsDepth) {
            return $Json | ConvertFrom-Json -Depth $Depth
        }
        return $Json | ConvertFrom-Json
    }
}

function Get-Sha256HashBytes {
    param([byte[]] $Bytes)

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        return $algorithm.ComputeHash($Bytes)
    }
    finally {
        $algorithm.Dispose()
    }
}

function ConvertTo-HexString {
    param([byte[]] $Bytes)

    return [System.BitConverter]::ToString($Bytes).Replace('-', '')
}

function Get-RelativePath {
    param(
        [string] $BasePath,
        [string] $Path
    )

    $method = [System.IO.Path].GetMethod(
        'GetRelativePath',
        [type[]]@([string], [string])
    )
    if ($null -ne $method) {
        return [System.IO.Path]::GetRelativePath($BasePath, $Path)
    }

    $baseFullPath = [System.IO.Path]::GetFullPath($BasePath).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar
    $pathFullPath = [System.IO.Path]::GetFullPath($Path)
    $baseUri = [Uri]::new($baseFullPath)
    $pathUri = [Uri]::new($pathFullPath)
    $relativeUri = $baseUri.MakeRelativeUri($pathUri)
    if ($relativeUri.IsAbsoluteUri) {
        return $pathFullPath
    }
    return [Uri]::UnescapeDataString($relativeUri.ToString()).Replace(
        [System.IO.Path]::AltDirectorySeparatorChar,
        [System.IO.Path]::DirectorySeparatorChar
    )
}

function Test-FixedTimeByteArrayEqual {
    param(
        [byte[]] $Left,
        [byte[]] $Right
    )

    if ($null -eq $Left -or $null -eq $Right -or $Left.Length -ne $Right.Length) {
        return $false
    }
    $difference = 0
    for ($index = 0; $index -lt $Left.Length; $index++) {
        $difference = $difference -bor ($Left[$index] -bxor $Right[$index])
    }
    return $difference -eq 0
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
            return $responseBody | ConvertFrom-JsonText -Depth 100
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
