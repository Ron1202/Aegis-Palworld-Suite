#requires -Version 5.1
<#
.SYNOPSIS
    Builds a complete Paldeck item database from a text file containing item-detail URLs.

.DESCRIPTION
    Reads URLs from Input\Items.txt, downloads each server-rendered Paldeck item page,
    extracts item metadata, optionally downloads icons, and exports JSON, CSV, command,
    audit, and launcher-friendly files.

    Designed for Windows PowerShell 5.1 and PowerShell 7+.
#>

[CmdletBinding()]
param(
    [string]$InputFile,
    [string]$OutputDirectory,
    [string]$CacheDirectory,
    [string]$LogDirectory,
    [int]$Quantity = 9999,
    [int]$DelayMilliseconds = 175,
    [int]$TimeoutSeconds = 45,
    [int]$MaximumRetries = 4,
    [switch]$DownloadIcons,
    [switch]$RefreshCache,
    [switch]$RetryFailuresOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Resolve the script directory after parameter binding. In Windows PowerShell 5.1,
# $PSScriptRoot can be empty while default parameter expressions are evaluated.
$ScriptDirectory = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptDirectory)) {
    $ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ([string]::IsNullOrWhiteSpace($ScriptDirectory)) {
    $ScriptDirectory = (Get-Location).Path
}

if ([string]::IsNullOrWhiteSpace($InputFile)) {
    $InputFile = Join-Path $ScriptDirectory 'Input\Items.txt'
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $ScriptDirectory 'Output'
}
if ([string]::IsNullOrWhiteSpace($CacheDirectory)) {
    $CacheDirectory = Join-Path $ScriptDirectory 'Cache\Pages'
}
if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
    $LogDirectory = Join-Path $ScriptDirectory 'Logs'
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {}

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/150 Safari/537.36 Aegis-Paldeck-Importer/1.0'

foreach ($directory in @($OutputDirectory, $CacheDirectory, $LogDirectory, (Join-Path $OutputDirectory 'Icons'))) {
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
}

$RunStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$RunLog = Join-Path $LogDirectory "Import-$RunStamp.log"
$FailurePath = Join-Path $OutputDirectory 'failed-items.json'
$CheckpointPath = Join-Path $OutputDirectory 'checkpoint-items.json'

function Write-RunLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS')][string]$Level = 'INFO'
    )
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    [System.IO.File]::AppendAllText($RunLog, $line + [Environment]::NewLine, $Utf8NoBom)
    switch ($Level) {
        'WARN'    { Write-Host $line -ForegroundColor Yellow }
        'ERROR'   { Write-Host $line -ForegroundColor Red }
        'SUCCESS' { Write-Host $line -ForegroundColor Green }
        default   { Write-Host $line }
    }
}

function Get-SafeFileName {
    param([Parameter(Mandatory)][string]$Name)
    $invalid = [IO.Path]::GetInvalidFileNameChars()
    $safe = $Name
    foreach ($character in $invalid) {
        $safe = $safe.Replace([string]$character, '_')
    }
    if ($safe.Length -gt 180) { $safe = $safe.Substring(0, 180) }
    return $safe
}

function Get-AssetIdFromUrl {
    param([Parameter(Mandatory)][string]$Url)
    try {
        $uri = [Uri]$Url
        return [Uri]::UnescapeDataString($uri.Segments[-1].Trim('/'))
    } catch {
        return ($Url -replace '^.*/items/', '').Trim('/')
    }
}

function Get-MetaContent {
    param(
        [Parameter(Mandatory)][string]$Html,
        [Parameter(Mandatory)][string]$Name
    )

    $escaped = [regex]::Escape($Name)
    $patterns = @(
        '<meta[^>]+(?:property|name)\s*=\s*["'']' + $escaped + '["''][^>]+content\s*=\s*["''](?<value>.*?)["''][^>]*>',
        '<meta[^>]+content\s*=\s*["''](?<value>.*?)["''][^>]+(?:property|name)\s*=\s*["'']' + $escaped + '["''][^>]*>'
    )

    foreach ($pattern in $patterns) {
        $match = [regex]::Match($Html, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            return [Net.WebUtility]::HtmlDecode($match.Groups['value'].Value).Trim()
        }
    }
    return $null
}

function Convert-HtmlToNormalizedLines {
    param([Parameter(Mandatory)][string]$Html)

    $text = $Html
    $text = [regex]::Replace($text, '<script\b[^>]*>.*?</script>', '', 'IgnoreCase,Singleline')
    $text = [regex]::Replace($text, '<style\b[^>]*>.*?</style>', '', 'IgnoreCase,Singleline')
    $text = [regex]::Replace($text, '<noscript\b[^>]*>.*?</noscript>', '', 'IgnoreCase,Singleline')
    $text = [regex]::Replace($text, '<(?:br|hr)\s*/?>', "`n", 'IgnoreCase')
    $text = [regex]::Replace($text, '</(?:p|div|section|article|main|header|footer|h1|h2|h3|h4|h5|li|dt|dd|tr|td|th)>', "`n", 'IgnoreCase')
    $text = [regex]::Replace($text, '<[^>]+>', ' ')
    $text = [Net.WebUtility]::HtmlDecode($text)
    $text = $text.Replace([char]0xA0, ' ')
    $text = [regex]::Replace($text, '[ \t]+', ' ')
    $text = [regex]::Replace($text, "(`r?`n)\s+", '$1')

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($text -split "`r?`n")) {
        $clean = $line.Trim()
        if ($clean) { $lines.Add($clean) }
    }
    return ,$lines.ToArray()
}

function Find-LineIndex {
    param(
        [string[]]$Lines,
        [string]$Text,
        [int]$StartAt = 0
    )
    for ($i = [Math]::Max(0, $StartAt); $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -eq $Text) { return $i }
    }
    return -1
}

function Get-ValueAfterLabel {
    param(
        [string[]]$Lines,
        [string]$Label,
        [int]$StartAt = 0
    )
    $index = Find-LineIndex -Lines $Lines -Text $Label -StartAt $StartAt
    if ($index -ge 0 -and ($index + 1) -lt $Lines.Count) {
        return $Lines[$index + 1]
    }
    return $null
}

function Get-SectionText {
    param(
        [string[]]$Lines,
        [string]$StartLabel,
        [string[]]$EndLabels
    )
    $start = Find-LineIndex -Lines $Lines -Text $StartLabel
    if ($start -lt 0) { return $null }

    $end = $Lines.Count
    foreach ($endLabel in $EndLabels) {
        $candidate = Find-LineIndex -Lines $Lines -Text $endLabel -StartAt ($start + 1)
        if ($candidate -ge 0 -and $candidate -lt $end) { $end = $candidate }
    }

    if ($end -le ($start + 1)) { return $null }
    return (($Lines[($start + 1)..($end - 1)] -join ' ') -replace '\s+', ' ').Trim()
}

function Invoke-DownloadText {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$CachePath
    )

    if ((Test-Path -LiteralPath $CachePath) -and -not $RefreshCache) {
        return [IO.File]::ReadAllText($CachePath)
    }

    $lastError = $null
    for ($attempt = 1; $attempt -le $MaximumRetries; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -UserAgent $UserAgent -TimeoutSec $TimeoutSeconds -Headers @{
                Accept = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
                'Accept-Language' = 'en-US,en;q=0.9'
                Referer = 'https://paldeck.cc/items'
            }
            if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300) {
                throw "HTTP $($response.StatusCode)"
            }
            $html = [string]$response.Content
            if ([string]::IsNullOrWhiteSpace($html) -or $html.Length -lt 500) {
                throw "Response was unexpectedly short ($($html.Length) characters)."
            }
            [IO.File]::WriteAllText($CachePath, $html, $Utf8NoBom)
            return $html
        } catch {
            $lastError = $_
            if ($attempt -lt $MaximumRetries) {
                $backoff = [Math]::Min(8000, 750 * [Math]::Pow(2, $attempt - 1))
                Write-RunLog "Attempt $attempt/$MaximumRetries failed for ${Url}: $($_.Exception.Message). Retrying in $backoff ms." 'WARN'
                Start-Sleep -Milliseconds $backoff
            }
        }
    }
    throw $lastError
}

function Convert-PaldeckPageToItem {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Html
    )

    $assetIdFromUrl = Get-AssetIdFromUrl $Url
    $lines = Convert-HtmlToNormalizedLines $Html

    $detailsIndex = Find-LineIndex -Lines $lines -Text 'Item Details'
    $propertiesIndex = Find-LineIndex -Lines $lines -Text 'Properties'
    $assetName = Get-ValueAfterLabel -Lines $lines -Label 'Asset Name' -StartAt ([Math]::Max(0, $detailsIndex))
    if (-not $assetName) { $assetName = $assetIdFromUrl }

    $title = Get-MetaContent -Html $Html -Name 'og:title'
    if ($title) { $title = ($title -replace '\s*\|\s*Paldeck\s*$', '').Trim() }
    if (-not $title) {
        $h1 = [regex]::Match($Html, '<h1[^>]*>(?<value>.*?)</h1>', 'IgnoreCase,Singleline')
        if ($h1.Success) {
            $title = [Net.WebUtility]::HtmlDecode(([regex]::Replace($h1.Groups['value'].Value, '<[^>]+>', ' '))).Trim()
        }
    }
    if (-not $title) { $title = $assetName }

    $number = $null
    foreach ($line in $lines) {
        if ($line -match '^#(?<number>\d+)$') {
            $number = [int]$Matches['number']
            break
        }
    }

    $category = Get-ValueAfterLabel -Lines $lines -Label 'Category' -StartAt ([Math]::Max(0, $detailsIndex))
    $typeA = Get-ValueAfterLabel -Lines $lines -Label 'Type A' -StartAt ([Math]::Max(0, $detailsIndex))
    $typeB = Get-ValueAfterLabel -Lines $lines -Label 'Type B' -StartAt ([Math]::Max(0, $detailsIndex))
    $rank = Get-ValueAfterLabel -Lines $lines -Label 'Rank' -StartAt ([Math]::Max(0, $detailsIndex))
    $rarity = Get-ValueAfterLabel -Lines $lines -Label 'Rarity' -StartAt ([Math]::Max(0, $detailsIndex))
    $description = Get-SectionText -Lines $lines -StartLabel 'Description' -EndLabels @('Recipe', 'Item Details', 'Properties')

    $imageUrl = Get-MetaContent -Html $Html -Name 'og:image'
    if (-not $imageUrl) { $imageUrl = Get-MetaContent -Html $Html -Name 'twitter:image' }
    if ($imageUrl -and $imageUrl.StartsWith('/')) { $imageUrl = 'https://paldeck.cc' + $imageUrl }

    $propertyNames = @(
        'Price','Weight','Stack Size','Sneak Attack Rate','Durability','Attack','Defense',
        'HP','Work Speed','Stamina','Max Weight','Sanity','Nutrition','SAN','Recovery',
        'Capture Power','Technology Points','Ancient Technology Points'
    )
    $properties = [ordered]@{}
    foreach ($propertyName in $propertyNames) {
        $value = Get-ValueAfterLabel -Lines $lines -Label $propertyName -StartAt ([Math]::Max(0, $propertiesIndex))
        if ($null -ne $value -and $value -notin @('Paldeck','OTHER DATABASES','RESOURCES','SUPPORT')) {
            $properties[$propertyName] = $value
        }
    }

    $recipeCrafts = Get-ValueAfterLabel -Lines $lines -Label 'Crafts'
    $workAmount = Get-ValueAfterLabel -Lines $lines -Label 'Work Amount'

    return [pscustomobject][ordered]@{
        Number       = $number
        Name         = $title
        AssetId      = $assetName
        TechnologyId = $assetName
        Category     = $category
        TypeA        = $typeA
        TypeB        = $typeB
        Rank         = if ($rank -match '^-?\d+$') { [int]$rank } else { $rank }
        Rarity       = if ($rarity -match '^-?\d+$') { [int]$rarity } else { $rarity }
        Description  = $description
        Price        = $properties['Price']
        Weight       = $properties['Weight']
        StackSize    = $properties['Stack Size']
        ImageUrl     = $imageUrl
        LocalIcon    = $null
        RecipeCrafts = $recipeCrafts
        WorkAmount   = $workAmount
        Properties   = [pscustomobject]$properties
        PaldeckUrl   = $Url
        CommandGive  = "!give $assetName`:$Quantity"
        CommandGiveMe = "!giveme $assetName`:$Quantity"
        ImportedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
}

function Save-Checkpoint {
    param([object[]]$Items)
    $json = $Items | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($CheckpointPath, $json, $Utf8NoBom)
}

if (-not (Test-Path -LiteralPath $InputFile)) {
    throw "Input file not found: $InputFile"
}

$rawUrls = Get-Content -LiteralPath $InputFile -ErrorAction Stop |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and $_ -match '^https://paldeck\.cc/items/[^/?#]+/?$' }

$urls = @($rawUrls | Sort-Object -Unique)
if ($urls.Count -eq 0) {
    throw 'No valid https://paldeck.cc/items/<AssetId> URLs were found.'
}

$priorFailures = @{}
if ($RetryFailuresOnly) {
    if (-not (Test-Path -LiteralPath $FailurePath)) {
        throw "RetryFailuresOnly was specified, but no failure file exists: $FailurePath"
    }
    foreach ($failure in (Get-Content -LiteralPath $FailurePath -Raw | ConvertFrom-Json)) {
        $priorFailures[[string]$failure.Url] = $true
    }
    $urls = @($urls | Where-Object { $priorFailures.ContainsKey($_) })
}

$items = New-Object System.Collections.Generic.List[object]
$failures = New-Object System.Collections.Generic.List[object]

if ((Test-Path -LiteralPath $CheckpointPath) -and -not $RefreshCache -and -not $RetryFailuresOnly) {
    try {
        $checkpointItems = @(Get-Content -LiteralPath $CheckpointPath -Raw | ConvertFrom-Json)
        foreach ($checkpointItem in $checkpointItems) { $items.Add($checkpointItem) }
        Write-RunLog "Loaded $($items.Count) records from the checkpoint."
    } catch {
        Write-RunLog "Checkpoint could not be loaded and will be rebuilt: $($_.Exception.Message)" 'WARN'
    }
}

$completed = @{}
foreach ($item in $items) {
    if ($item.PaldeckUrl) { $completed[[string]$item.PaldeckUrl] = $true }
}

Write-RunLog "Starting import. Valid unique URLs: $($urls.Count). Existing checkpoint records: $($items.Count)."
Write-RunLog "Icon downloading: $([bool]$DownloadIcons). Delay: $DelayMilliseconds ms. Retries: $MaximumRetries."

$processedThisRun = 0
for ($index = 0; $index -lt $urls.Count; $index++) {
    $url = [string]$urls[$index]
    if ($completed.ContainsKey($url)) { continue }

    $assetId = Get-AssetIdFromUrl $url
    $safeAssetId = Get-SafeFileName $assetId
    $cachePath = Join-Path $CacheDirectory "$safeAssetId.html"

    $position = $index + 1
    $percent = [Math]::Floor(($position / [double]$urls.Count) * 100)
    Write-Progress -Activity 'Building Paldeck item database' -Status "$position / $($urls.Count): $assetId" -PercentComplete $percent

    try {
        $html = Invoke-DownloadText -Url $url -CachePath $cachePath
        $item = Convert-PaldeckPageToItem -Url $url -Html $html

        if (-not $item.AssetId) { throw 'Asset ID could not be extracted.' }
        if (-not $item.Name) { throw 'Display name could not be extracted.' }

        if ($DownloadIcons -and $item.ImageUrl) {
            try {
                $extension = [IO.Path]::GetExtension(([Uri]$item.ImageUrl).AbsolutePath)
                if (-not $extension -or $extension.Length -gt 6) { $extension = '.webp' }
                $iconName = "$safeAssetId$extension"
                $iconPath = Join-Path (Join-Path $OutputDirectory 'Icons') $iconName
                if (-not (Test-Path -LiteralPath $iconPath) -or $RefreshCache) {
                    Invoke-WebRequest -Uri $item.ImageUrl -UseBasicParsing -UserAgent $UserAgent -TimeoutSec $TimeoutSeconds -OutFile $iconPath
                }
                $item.LocalIcon = "Icons/$iconName"
            } catch {
                Write-RunLog "Icon failed for ${assetId}: $($_.Exception.Message)" 'WARN'
            }
        }

        $items.Add($item)
        $completed[$url] = $true
        $processedThisRun++

        if (($processedThisRun % 25) -eq 0) {
            Save-Checkpoint -Items @($items)
            Write-RunLog "Checkpoint saved: $($items.Count) successful records."
        }

        Write-RunLog "[$position/$($urls.Count)] Imported $($item.Name) [$($item.AssetId)]" 'SUCCESS'
    } catch {
        $failure = [pscustomobject][ordered]@{
            Url = $url
            AssetId = $assetId
            Error = $_.Exception.Message
            OccurredAtUtc = [DateTime]::UtcNow.ToString('o')
        }
        $failures.Add($failure)
        Write-RunLog "[$position/$($urls.Count)] Failed ${assetId}: $($_.Exception.Message)" 'ERROR'
    }

    if ($DelayMilliseconds -gt 0) {
        Start-Sleep -Milliseconds $DelayMilliseconds
    }
}

Write-Progress -Activity 'Building Paldeck item database' -Completed

# Deduplicate by AssetId, preserving the newest parsed record.
$finalItems = @(
    $items |
    Where-Object { $_.AssetId } |
    Group-Object -Property AssetId |
    ForEach-Object { $_.Group[-1] } |
    Sort-Object @{Expression={ if ($null -eq $_.Number) { [int]::MaxValue } else { [int]$_.Number }}}, AssetId
)

$itemsJsonPath = Join-Path $OutputDirectory 'items.json'
$technologyJsonPath = Join-Path $OutputDirectory 'technologyids.json'
$itemsCsvPath = Join-Path $OutputDirectory 'items.csv'
$givePath = Join-Path $OutputDirectory 'give-commands.txt'
$giveMePath = Join-Path $OutputDirectory 'giveme-commands.txt'
$launcherPath = Join-Path $OutputDirectory 'aegis-items.json'
$auditPath = Join-Path $OutputDirectory 'import-audit.json'

[IO.File]::WriteAllText($itemsJsonPath, ($finalItems | ConvertTo-Json -Depth 8), $Utf8NoBom)

$technologyRecords = @($finalItems | ForEach-Object {
    [pscustomobject][ordered]@{
        Name = $_.Name
        TechnologyId = $_.AssetId
        AssetId = $_.AssetId
        Category = $_.Category
        Icon = $_.LocalIcon
        ImageUrl = $_.ImageUrl
        PaldeckUrl = $_.PaldeckUrl
    }
})
[IO.File]::WriteAllText($technologyJsonPath, ($technologyRecords | ConvertTo-Json -Depth 5), $Utf8NoBom)

$launcherRecords = @($finalItems | ForEach-Object {
    [pscustomobject][ordered]@{
        Name = $_.Name
        DisplayName = $_.Name
        AssetId = $_.AssetId
        TechnologyId = $_.AssetId
        Category = $_.Category
        Description = $_.Description
        Icon = $_.LocalIcon
        IconUrl = $_.ImageUrl
        StackSize = $_.StackSize
        Weight = $_.Weight
        Rarity = $_.Rarity
        PaldeckUrl = $_.PaldeckUrl
    }
})
[IO.File]::WriteAllText($launcherPath, ($launcherRecords | ConvertTo-Json -Depth 5), $Utf8NoBom)

$finalItems |
    Select-Object Number,Name,AssetId,TechnologyId,Category,TypeA,TypeB,Rank,Rarity,Price,Weight,StackSize,Description,ImageUrl,LocalIcon,PaldeckUrl,CommandGive,CommandGiveMe |
    Export-Csv -LiteralPath $itemsCsvPath -NoTypeInformation -Encoding UTF8

[IO.File]::WriteAllLines($givePath, @($finalItems | ForEach-Object { "!give $($_.AssetId):$Quantity" }), $Utf8NoBom)
[IO.File]::WriteAllLines($giveMePath, @($finalItems | ForEach-Object { "!giveme $($_.AssetId):$Quantity" }), $Utf8NoBom)
[IO.File]::WriteAllText($FailurePath, ($failures | ConvertTo-Json -Depth 5), $Utf8NoBom)

$audit = [pscustomobject][ordered]@{
    StartedFrom = $InputFile
    CompletedAtUtc = [DateTime]::UtcNow.ToString('o')
    InputLineCount = @($rawUrls).Count
    UniqueValidUrlCount = $urls.Count
    SuccessfulItemCount = $finalItems.Count
    FailedItemCount = $failures.Count
    DownloadIcons = [bool]$DownloadIcons
    Quantity = $Quantity
    OutputFiles = @(
        'items.json','technologyids.json','aegis-items.json','items.csv',
        'give-commands.txt','giveme-commands.txt','failed-items.json'
    )
}
[IO.File]::WriteAllText($auditPath, ($audit | ConvertTo-Json -Depth 5), $Utf8NoBom)

Save-Checkpoint -Items $finalItems

Write-RunLog "Import complete. Successful: $($finalItems.Count). Failed this run: $($failures.Count)." 'SUCCESS'
Write-RunLog "Primary launcher database: $launcherPath" 'SUCCESS'
Write-Host ''
Write-Host 'Generated files:' -ForegroundColor Cyan
Write-Host "  $itemsJsonPath"
Write-Host "  $technologyJsonPath"
Write-Host "  $launcherPath"
Write-Host "  $itemsCsvPath"
Write-Host "  $givePath"
Write-Host "  $giveMePath"
Write-Host "  $FailurePath"
Write-Host "  $auditPath"
Write-Host ''
Write-Host 'Press Enter to close.' -ForegroundColor DarkGray
[void](Read-Host)
