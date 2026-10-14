function Get-AuthPath {
    param([string] $GitHubHost)

    $safeHost = $GitHubHost -replace '[^a-zA-Z0-9.-]', '_'
    return Join-Path (Join-Path $HOME '.psopencode') "auth-$safeHost.json"
}

function Save-GitHubToken {
    param(
        [string] $GitHubHost,
        [string] $Token
    )

    $path = Get-AuthPath -GitHubHost $GitHubHost
    $document = [ordered]@{
        host           = $GitHubHost
        protection     = Get-SecretProtectionMethod
        protectedToken = Protect-StoredSecret -Value $Token
    }
    Write-SecureJsonFile -Path $path -Document $document
}

function Get-GitHubToken {
    param([string] $GitHubHost)

    if ($env:PSOPENCODE_GITHUB_TOKEN) {
        return $env:PSOPENCODE_GITHUB_TOKEN
    }

    $path = Get-AuthPath -GitHubHost $GitHubHost
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }

    $document = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
    $protection = [string](Get-PropertyValue -Object $document -Name 'protection' -Default 'dpapi')
    return Unprotect-StoredSecret -Protection $protection -Value (
        [string](Get-PropertyValue -Object $document -Name 'protectedToken' -Default '')
    )
}

function Remove-GitHubToken {
    param([string] $GitHubHost)

    $path = Get-AuthPath -GitHubHost $GitHubHost
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Connect-GitHubDevice {
    param([string] $GitHubHost)

    $baseUri = "https://$GitHubHost"
    $device = Invoke-JsonRequest -Method Post -Uri "$baseUri/login/device/code" `
        -Headers @{ Accept = 'application/json' } `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{
            client_id = $script:OAuthClientId
            scope     = 'read:user'
        } `
        -Operation "Starting device login at $GitHubHost"

    Write-Host ''
    Write-Host 'Sign in with your Microsoft credentials:' -ForegroundColor Cyan
    Write-Host $device.verification_uri
    Write-Host "Code: $($device.user_code)" -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Waiting for authorization...' -ForegroundColor DarkGray

    $interval = [Math]::Max([int]$device.interval, 5)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds([int]$device.expires_in)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds $interval
        $tokenResult = Invoke-JsonRequest -Method Post `
            -Uri "$baseUri/login/oauth/access_token" `
            -Headers @{ Accept = 'application/json' } `
            -ContentType 'application/x-www-form-urlencoded' `
            -Body @{
                client_id   = $script:OAuthClientId
                device_code = $device.device_code
                grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
            } `
            -Operation "Polling device login at $GitHubHost"

        $accessToken = Get-PropertyValue -Object $tokenResult -Name 'access_token'
        if ($accessToken) {
            Save-GitHubToken -GitHubHost $GitHubHost -Token $accessToken
            return $accessToken
        }

        $deviceError = Get-PropertyValue -Object $tokenResult -Name 'error'
        switch ($deviceError) {
            'authorization_pending' {
                continue
            }
            'slow_down' {
                $interval += 5
                continue
            }
            'access_denied' {
                throw 'Login was denied.'
            }
            'expired_token' {
                throw 'The device code expired. Run -Login again.'
            }
            default {
                $description = Get-PropertyValue -Object $tokenResult -Name 'error_description'
                throw "Device login failed: $($description ?? $deviceError)"
            }
        }
    }

    throw 'The device code expired. Run -Login again.'
}
