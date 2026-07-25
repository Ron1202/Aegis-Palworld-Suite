param(
    [switch]$Force,
    [int]$TimeoutSeconds = 25
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$EngineRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $EngineRoot
$DatabaseFile = Join-Path $Root "Database\items.json"
$IconDirectory = Join-Path $Root "Icons"
$FallbackRelative = "Icons/_fallback.png"
$FallbackPath = Join-Path $Root "Icons\_fallback.png"
$LogDirectory = Join-Path $Root "Logs"
$TempDirectory = Join-Path $env:TEMP ("AegisIconRepair-" + [guid]::NewGuid().ToString("N"))

New-Item -ItemType Directory -Path $IconDirectory,$LogDirectory,$TempDirectory -Force | Out-Null
$LogFile = Join-Path $LogDirectory ("Icon-Repair-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log")
try { Start-Transcript -Path $LogFile -Force | Out-Null } catch {}

function Find-Browser {
    $paths = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "$env:ProgramFiles(x86)\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles(x86)\Microsoft\Edge\Application\msedge.exe",
        "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe",
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\Application\brave.exe"
    )

    foreach ($path in $paths) {
        if (Test-Path $path) { return $path }
    }

    foreach ($name in @("chrome.exe","msedge.exe","brave.exe")) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }

    throw "Chrome, Edge, or Brave is required to convert Paldeck WebP artwork into WPF-compatible PNG files."
}

function Test-WebP {
    param([string]$Path)

    if (-not (Test-Path $Path)) { return $false }
    if ((Get-Item $Path).Length -lt 100) { return $false }

    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -lt 12) { return $false }
        $header = [Text.Encoding]::ASCII.GetString($bytes,0,12)
        return ($header.StartsWith("RIFF") -and $header.Contains("WEBP"))
    }
    catch {
        return $false
    }
}

function Test-Png {
    param([string]$Path)

    if (-not (Test-Path $Path)) { return $false }
    if ((Get-Item $Path).Length -lt 100) { return $false }

    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -lt 8) { return $false }
        $signature = @([byte]137,80,78,71,13,10,26,10)
        for ($i=0; $i -lt 8; $i++) {
            if ($bytes[$i] -ne $signature[$i]) { return $false }
        }
        return $true
    }
    catch {
        return $false
    }
}


function Remove-EdgeConnectedMatte {
    param(
        [Parameter(Mandatory)][string]$PngPath
    )

    if (-not (Test-Png $PngPath)) { return $false }

    $backgroundR = 1
    $backgroundG = 6
    $backgroundB = 11

    try {
        $source = New-Object Drawing.Bitmap $PngPath
        $bitmap = New-Object Drawing.Bitmap $source.Width,$source.Height,[Drawing.Imaging.PixelFormat]::Format32bppArgb

        try {
            $graphics = [Drawing.Graphics]::FromImage($bitmap)
            try {
                $graphics.DrawImageUnscaled($source,0,0)
            }
            finally {
                $graphics.Dispose()
            }

            $width = $bitmap.Width
            $height = $bitmap.Height
            $visited = New-Object 'bool[,]' $width,$height
            $queue = New-Object 'Collections.Generic.Queue[System.Drawing.Point]'

            function Test-MattePixel {
                param([Drawing.Color]$Color)

                # Preserve bright/colorful item pixels. Remove only dark,
                # low-saturation background/checker pixels.
                $max = [Math]::Max($Color.R,[Math]::Max($Color.G,$Color.B))
                $min = [Math]::Min($Color.R,[Math]::Min($Color.G,$Color.B))
                $spread = $max - $min
                $brightness = ($Color.R + $Color.G + $Color.B) / 3.0

                $nearSuiteBackground = (
                    [Math]::Abs($Color.R - $backgroundR) -le 26 -and
                    [Math]::Abs($Color.G - $backgroundG) -le 26 -and
                    [Math]::Abs($Color.B - $backgroundB) -le 26
                )

                $grayMatte = (
                    $spread -le 18 -and
                    $brightness -le 115
                )

                $veryDark = (
                    $max -le 48
                )

                return ($nearSuiteBackground -or $grayMatte -or $veryDark)
            }

            # Seed the flood fill from every border pixel that looks like matte.
            for ($x=0; $x -lt $width; $x++) {
                foreach ($y in @(0,$height-1)) {
                    if (-not $visited[$x,$y] -and (Test-MattePixel $bitmap.GetPixel($x,$y))) {
                        $visited[$x,$y] = $true
                        $queue.Enqueue([Drawing.Point]::new($x,$y))
                    }
                }
            }

            for ($y=0; $y -lt $height; $y++) {
                foreach ($x in @(0,$width-1)) {
                    if (-not $visited[$x,$y] -and (Test-MattePixel $bitmap.GetPixel($x,$y))) {
                        $visited[$x,$y] = $true
                        $queue.Enqueue([Drawing.Point]::new($x,$y))
                    }
                }
            }

            $directions = @(
                [Drawing.Point]::new(-1,0),
                [Drawing.Point]::new(1,0),
                [Drawing.Point]::new(0,-1),
                [Drawing.Point]::new(0,1),
                [Drawing.Point]::new(-1,-1),
                [Drawing.Point]::new(1,-1),
                [Drawing.Point]::new(-1,1),
                [Drawing.Point]::new(1,1)
            )

            $replacement = [Drawing.Color]::FromArgb(255,$backgroundR,$backgroundG,$backgroundB)

            while ($queue.Count -gt 0) {
                $point = $queue.Dequeue()
                $bitmap.SetPixel($point.X,$point.Y,$replacement)

                foreach ($direction in $directions) {
                    $nx = $point.X + $direction.X
                    $ny = $point.Y + $direction.Y

                    if (
                        $nx -ge 0 -and $nx -lt $width -and
                        $ny -ge 0 -and $ny -lt $height -and
                        -not $visited[$nx,$ny]
                    ) {
                        $visited[$nx,$ny] = $true
                        $color = $bitmap.GetPixel($nx,$ny)

                        if (Test-MattePixel $color) {
                            $queue.Enqueue([Drawing.Point]::new($nx,$ny))
                        }
                    }
                }
            }

            # Replace the file atomically.
            $cleanedPath = [IO.Path]::ChangeExtension(
                [IO.Path]::Combine(
                    [IO.Path]::GetDirectoryName($PngPath),
                    [IO.Path]::GetFileNameWithoutExtension($PngPath) + ".clean"
                ),
                ".png"
            )

            $bitmap.Save($cleanedPath,[Drawing.Imaging.ImageFormat]::Png)
            $source.Dispose()
            $source = $null
            $bitmap.Dispose()
            $bitmap = $null

            Move-Item $cleanedPath $PngPath -Force
            if (-not (Test-Png $PngPath)) { return $false }

        # Remove only gray/black pixels connected to the image border.
        # This preserves the actual item, including silver or gray metal.
        Remove-EdgeConnectedMatte -PngPath $PngPath | Out-Null
        return (Test-Png $PngPath)
        }
        finally {
            if ($source) { $source.Dispose() }
            if ($bitmap) { $bitmap.Dispose() }
        }
    }
    catch {
        return $false
    }
}

function Convert-WebPToPng {
    param(
        [Parameter(Mandatory)][string]$Browser,
        [Parameter(Mandatory)][string]$WebPPath,
        [Parameter(Mandatory)][string]$PngPath
    )

    if (-not (Test-WebP $WebPPath)) { return $false }

    $htmlPath = Join-Path $TempDirectory ("render-" + [guid]::NewGuid().ToString("N") + ".html")
    $fileUri = ([Uri]$WebPPath).AbsoluteUri
    $html = @"
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<style>
html,body{margin:0;width:128px;height:128px;overflow:hidden;background:#01060B}
body{display:flex;align-items:center;justify-content:center}
img{display:block;width:116px;height:116px;object-fit:contain;object-position:center}
</style>
</head>
<body><img src="$fileUri"></body>
</html>
"@
    [IO.File]::WriteAllText($htmlPath,$html,[Text.UTF8Encoding]::new($false))

    Remove-Item $PngPath -Force -ErrorAction SilentlyContinue

    $arguments = @(
        "--headless=new",
        "--disable-gpu",
        "--hide-scrollbars",
        "--allow-file-access-from-files",
        "--window-size=128,128",
        "--virtual-time-budget=1500",
        "--screenshot=$PngPath",
        ([Uri]$htmlPath).AbsoluteUri
    )

    try {
        $process = Start-Process `
            -FilePath $Browser `
            -ArgumentList $arguments `
            -PassThru `
            -WindowStyle Hidden

        if (-not $process.WaitForExit(20000)) {
            Stop-Process $process.Id -Force -ErrorAction SilentlyContinue
            return $false
        }

        return (Test-Png $PngPath)
    }
    catch {
        return $false
    }
    finally {
        Remove-Item $htmlPath -Force -ErrorAction SilentlyContinue
    }
}

function Copy-PngFromExistingCaches {
    param(
        [Parameter(Mandatory)][string]$Filename,
        [Parameter(Mandatory)][string]$Destination
    )

    $searchRoots = @(
        (Split-Path $Root -Parent),
        $(if ($env:USERPROFILE) { Join-Path $env:USERPROFILE "Downloads" })
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

    foreach ($searchRoot in $searchRoots) {
        $match = Get-ChildItem `
            -Path $searchRoot `
            -Filter $Filename `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -ne $Destination -and
                $_.FullName -match '\\Icons\\'
            } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if ($match) {
            try {
                Copy-Item $match.FullName $Destination -Force
                if (Test-Png $Destination) { return $true }
            }
            catch {}

            Remove-Item $Destination -Force -ErrorAction SilentlyContinue
        }
    }

    return $false
}

function Find-WebPInExistingCaches {
    param([Parameter(Mandatory)][string]$Filename)

    $searchRoots = @(
        $IconDirectory,
        (Split-Path $Root -Parent),
        $(if ($env:USERPROFILE) { Join-Path $env:USERPROFILE "Downloads" })
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

    foreach ($searchRoot in $searchRoots) {
        $match = Get-ChildItem `
            -Path $searchRoot `
            -Filter $Filename `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\Icons\\' } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if ($match -and (Test-WebP $match.FullName)) {
            return $match.FullName
        }
    }

    return $null
}

function Get-PageIconCandidates {
    param([string]$PageUrl)

    if (-not $PageUrl) { return @() }

    try {
        $response = Invoke-WebRequest `
            -UseBasicParsing `
            -Uri $PageUrl `
            -TimeoutSec $TimeoutSeconds `
            -Headers @{
                "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Aegis-Palworld-Suite"
                "Accept-Language" = "en-US,en;q=0.9"
            }

        $html = [string]$response.Content
        $matches = New-Object Collections.Generic.List[string]

        foreach ($pattern in @(
            '(?is)<meta[^>]+property=["'']og:image["''][^>]+content=["'']([^"'']+)["'']',
            '(?is)<meta[^>]+content=["'']([^"'']+)["''][^>]+property=["'']og:image["'']',
            '(?is)(https?://[^"''\s>]+\.webp(?:\?[^"''\s>]*)?)',
            '(?is)(/assets/palworld/items/[^"''\s>]+\.webp(?:\?[^"''\s>]*)?)'
        )) {
            foreach ($match in [regex]::Matches($html,$pattern)) {
                $value = [Net.WebUtility]::HtmlDecode($match.Groups[1].Value)
                if ($value.StartsWith('/')) {
                    $value = ([Uri]::new([Uri]$PageUrl,$value)).AbsoluteUri
                }
                if ($value -match '^https?://') {
                    $matches.Add($value)
                }
            }
        }

        return @($matches | Sort-Object -Unique)
    }
    catch {
        return @()
    }
}

function Download-WebP {
    param(
        [Parameter(Mandatory)][object]$Record,
        [Parameter(Mandatory)][string]$Destination
    )

    $id = [string]$Record.id
    $urls = New-Object Collections.Generic.List[string]
    $urls.Add("https://api.paldeck.cc/assets/palworld/items/T_itemicon_$id.webp")
    $urls.Add("https://paldeck.cc/assets/palworld/items/T_itemicon_$id.webp")

    foreach ($candidate in (Get-PageIconCandidates -PageUrl ([string]$Record.page))) {
        if (-not $urls.Contains($candidate)) {
            $urls.Add($candidate)
        }
    }

    foreach ($url in $urls) {
        try {
            Invoke-WebRequest `
                -UseBasicParsing `
                -Uri $url `
                -OutFile $Destination `
                -TimeoutSec $TimeoutSeconds `
                -Headers @{
                    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Aegis-Palworld-Suite"
                    "Accept" = "image/webp,image/*,*/*;q=0.8"
                    "Referer" = "https://paldeck.cc/"
                }

            if (Test-WebP $Destination) { return $url }
        }
        catch {}

        Remove-Item $Destination -Force -ErrorAction SilentlyContinue
    }

    return $null
}

if (-not (Test-Path $DatabaseFile)) {
    Write-Host "ERROR: Database\items.json is missing." -ForegroundColor Red
    exit 1
}

$db = [IO.File]::ReadAllText($DatabaseFile) | ConvertFrom-Json
$records = @($db.records)

if ($records.Count -lt 450) {
    Write-Host "ERROR: The database contains only $($records.Count) records." -ForegroundColor Red
    exit 1
}

$browser = Find-Browser

Write-Host ""
Write-Host "Aegis Palworld Suite PNG Icon Repair" -ForegroundColor Cyan
Write-Host "Browser converter: $browser" -ForegroundColor Gray
Write-Host "Rebuilding and de-matting $($records.Count) item thumbnails..." -ForegroundColor White
Write-Host ""

$existing = 0
$converted = 0
$downloaded = 0
$fallbacks = 0
$failedNames = New-Object Collections.Generic.List[string]
$index = 0

foreach ($record in $records) {
    $index++
    $safeId = ([string]$record.id) -replace '[^A-Za-z0-9_]', '_'
    $pngFilename = "$safeId.png"
    $webpFilename = "$safeId.webp"
    $pngPath = Join-Path $IconDirectory $pngFilename
    $relativePng = "Icons/$pngFilename"

    if (-not $Force -and (Test-Png $pngPath) -and $false) {
        $record.icon = $relativePng
        $existing++
    }
    elseif (Copy-PngFromExistingCaches -Filename $pngFilename -Destination $pngPath) {
        $record.icon = $relativePng
        $existing++
    }
    else {
        $webpPath = Find-WebPInExistingCaches -Filename $webpFilename
        $tempWebP = $null

        if (-not $webpPath) {
            $tempWebP = Join-Path $TempDirectory $webpFilename
            if (Download-WebP -Record $record -Destination $tempWebP) {
                $webpPath = $tempWebP
                $downloaded++
            }
        }

        if ($webpPath -and (Convert-WebPToPng -Browser $browser -WebPPath $webpPath -PngPath $pngPath)) {
            $record.icon = $relativePng
            $converted++
        }
        else {
            $record.icon = $FallbackRelative
            $fallbacks++
            $failedNames.Add("$($record.name) [$($record.id)]")
        }
    }

    if (($index % 20) -eq 0 -or $index -eq $records.Count) {
        Write-Host (
            "Processed {0}/{1} | PNG existing: {2} | Converted: {3} | Downloaded: {4} | Fallback: {5}" -f
            $index,$records.Count,$existing,$converted,$downloaded,$fallbacks
        ) -ForegroundColor DarkGray
    }
}

$db.count = $records.Count
$db.records = $records

[IO.File]::WriteAllText(
    $DatabaseFile,
    ($db | ConvertTo-Json -Depth 9),
    [Text.UTF8Encoding]::new($false)
)

$dataJs = Join-Path $Root "Database\data.js"
[IO.File]::WriteAllText(
    $dataJs,
    "window.PALWORLD_DATA=" + ($db | ConvertTo-Json -Depth 9 -Compress) + ";",
    [Text.UTF8Encoding]::new($false)
)

$report = Join-Path $Root "Database\Icon-Repair-Report.txt"
$reportLines = @(
    "Aegis Palworld Suite PNG Icon Repair Report",
    "============================================",
    "Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "Records scanned: $($records.Count)",
    "Existing PNG icons: $existing",
    "WebP icons converted to PNG: $converted",
    "WebP icons downloaded: $downloaded",
    "Fallbacks remaining: $fallbacks",
    "",
    "Items still using the fallback:"
) + @($failedNames)

[IO.File]::WriteAllLines(
    $report,
    $reportLines,
    [Text.UTF8Encoding]::new($false)
)

Write-Host ""
Write-Host "PNG icon repair completed." -ForegroundColor Green
Write-Host "Existing PNG: $existing" -ForegroundColor Gray
Write-Host "Converted:    $converted" -ForegroundColor Green
Write-Host "Fallbacks:    $fallbacks" -ForegroundColor Yellow
Write-Host "Report:       $report" -ForegroundColor Gray
Write-Host ""
Write-Host "Close and reopen Aegis Palworld Suite to display the PNG thumbnails." -ForegroundColor Cyan

Remove-Item $TempDirectory -Recurse -Force -ErrorAction SilentlyContinue
try { Stop-Transcript | Out-Null } catch {}
exit 0
