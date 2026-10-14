function Get-SessionDirectory {
    return Join-Path (Join-Path $HOME '.psopencode') 'sessions'
}

function New-SessionId {
    $stamp = [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss')
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 3)
    return "$stamp-$suffix"
}

function Get-SessionPath {
    param([string] $Id)

    $safeId = $Id -replace '[^a-zA-Z0-9._-]', '_'
    return Join-Path (Get-SessionDirectory) "$safeId.json"
}

function Get-MessageField {
    param(
        [object] $Message,
        [string] $Name
    )

    if ($Message -is [System.Collections.IDictionary]) {
        if ($Message.Contains($Name)) {
            return $Message[$Name]
        }
        return $null
    }
    return Get-PropertyValue -Object $Message -Name $Name
}

function Get-SessionTitle {
    param([System.Collections.Generic.List[object]] $Messages)

    foreach ($message in $Messages) {
        if ([string](Get-MessageField -Message $message -Name 'role') -ne 'user') {
            continue
        }
        $content = [string](Get-MessageField -Message $message -Name 'content')
        $firstLine = @($content -split "`n" | Where-Object { $_.Trim() })
        if ($firstLine.Count -eq 0) {
            continue
        }
        $title = $firstLine[0].Trim()
        if ($title.Length -gt 60) {
            return $title.Substring(0, 57) + '...'
        }
        return $title
    }
    return '(no prompt yet)'
}

function Save-Session {
    param(
        [string] $Id,
        [System.Collections.Generic.List[object]] $Messages,
        [string] $Model,
        [string] $Mode,
        [string] $Root
    )

    if ($Messages.Count -le 1) {
        return
    }
    $path = Get-SessionPath -Id $Id
    $created = [DateTimeOffset]::Now.ToString('o')
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $existing = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -Depth 100
            $existingCreated = [string](Get-PropertyValue -Object $existing -Name 'created' -Default '')
            if ($existingCreated) {
                $created = $existingCreated
            }
        }
        catch {
            # A corrupt existing file is overwritten with a fresh timestamp.
        }
    }
    $document = [ordered]@{
        id       = $Id
        created  = $created
        updated  = [DateTimeOffset]::Now.ToString('o')
        model    = $Model
        mode     = $Mode
        root     = $Root
        title    = Get-SessionTitle -Messages $Messages
        messages = @($Messages)
    }
    Write-SecureJsonFile -Path $path -Document $document -Depth 100
}

function Get-SessionSummaries {
    $directory = Get-SessionDirectory
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        return @()
    }
    $summaries = foreach ($file in Get-ChildItem -LiteralPath $directory -Filter '*.json' -File) {
        try {
            $document = [System.IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json -Depth 100
        }
        catch {
            continue
        }
        $messages = @(Get-PropertyValue -Object $document -Name 'messages' -Default @())
        $turns = @($messages | Where-Object {
            [string](Get-MessageField -Message $_ -Name 'role') -eq 'user'
        }).Count
        [pscustomobject]@{
            Id      = [string](Get-PropertyValue -Object $document -Name 'id' -Default $file.BaseName)
            Updated = [string](Get-PropertyValue -Object $document -Name 'updated' -Default '')
            Created = [string](Get-PropertyValue -Object $document -Name 'created' -Default '')
            Model   = [string](Get-PropertyValue -Object $document -Name 'model' -Default '-')
            Mode    = [string](Get-PropertyValue -Object $document -Name 'mode' -Default '-')
            Root    = [string](Get-PropertyValue -Object $document -Name 'root' -Default '')
            Turns   = $turns
            Title   = [string](Get-PropertyValue -Object $document -Name 'title' -Default '')
        }
    }
    return @($summaries | Sort-Object -Property Updated -Descending)
}

function Show-Sessions {
    $summaries = @(Get-SessionSummaries)
    if ($summaries.Count -eq 0) {
        Write-Host 'No saved sessions yet.' -ForegroundColor DarkGray
        return
    }
    $index = 0
    $rows = foreach ($summary in $summaries) {
        $index++
        $display = $summary.Updated
        $parsed = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse($summary.Updated, [ref]$parsed)) {
            $display = $parsed.LocalDateTime.ToString('yyyy-MM-dd HH:mm')
        }
        [pscustomobject]@{
            '#'     = $index
            Id      = $summary.Id
            Updated = $display
            Model   = $summary.Model
            Mode    = $summary.Mode
            Turns   = $summary.Turns
            Title   = $summary.Title
        }
    }
    $rows | Format-Table -AutoSize -Wrap
}

function Resolve-SessionReference {
    param([string] $Reference)

    $summaries = @(Get-SessionSummaries)
    $match = $summaries | Where-Object { $_.Id -eq $Reference } | Select-Object -First 1
    if ($match) {
        return $match.Id
    }
    if ($Reference -match '^\d+$') {
        $position = [int]$Reference
        if ($position -ge 1 -and $position -le $summaries.Count) {
            return $summaries[$position - 1].Id
        }
    }
    return $null
}

function Import-Session {
    param([string] $Id)

    $path = Get-SessionPath -Id $Id
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    $document = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -Depth 100
    $messages = [System.Collections.Generic.List[object]]::new()
    foreach ($message in @(Get-PropertyValue -Object $document -Name 'messages' -Default @())) {
        $messages.Add($message)
    }
    return [pscustomobject]@{
        Id       = [string](Get-PropertyValue -Object $document -Name 'id' -Default $Id)
        Model    = [string](Get-PropertyValue -Object $document -Name 'model' -Default '')
        Mode     = [string](Get-PropertyValue -Object $document -Name 'mode' -Default 'build')
        Root     = [string](Get-PropertyValue -Object $document -Name 'root' -Default '')
        Messages = $messages
    }
}
