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
