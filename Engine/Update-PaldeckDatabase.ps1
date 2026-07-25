param(
    [switch]$SkipIcons,
    [int]$MinimumRecordCount = 450
)

$ErrorActionPreference = "Stop"
$EngineRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $EngineRoot
$DatabaseDirectory = Join-Path $Root "Database"
$IconDirectory = Join-Path $Root "Icons"
$LogDirectory = Join-Path $Root "Logs"
$StagingDirectory = Join-Path $DatabaseDirectory ".staging"
$DataFile = Join-Path $DatabaseDirectory "items.json"
$DataJsFile = Join-Path $DatabaseDirectory "data.js"
$CommandFile = Join-Path $DatabaseDirectory "Palworld-Paldeck-Give-Commands.txt"
$AuditFile = Join-Path $DatabaseDirectory "Palworld-Database-Audit.txt"
$SqlFile = Join-Path $DatabaseDirectory "aegis-palworld.sql"
$SqliteFile = Join-Path $DatabaseDirectory "aegis-palworld.db"
$FallbackIcon = Join-Path $IconDirectory "_fallback.png"
$PaldeckUrl = "https://paldeck.cc/items"

New-Item -ItemType Directory -Path $DatabaseDirectory,$IconDirectory,$LogDirectory,$StagingDirectory -Force | Out-Null
$TranscriptFile = Join-Path $LogDirectory ("Database-Update-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log")
try { Start-Transcript -Path $TranscriptFile -Force | Out-Null } catch {}

function Find-Browser {
    $paths = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "$env:ProgramFiles(x86)\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
        "$env:ProgramFiles(x86)\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe",
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\Application\brave.exe"
    )
    foreach ($p in $paths) { if (Test-Path $p) { return $p } }
    foreach ($n in @("chrome.exe","msedge.exe","brave.exe")) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }
    throw "Install Google Chrome, Microsoft Edge, or Brave."
}

function Invoke-CdpExpression {
    param(
        [Parameter(Mandatory)][string]$Browser,
        [Parameter(Mandatory)][string]$InitialUrl,
        [Parameter(Mandatory)][string]$Expression
    )

    $port = Get-Random -Minimum 9300 -Maximum 9999
    $profile = Join-Path $env:TEMP ("AegisCDP-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $profile -Force | Out-Null

    $args = @(
        "--headless=new","--disable-gpu","--no-first-run","--disable-extensions",
        "--disable-background-networking","--disable-component-update",
        "--remote-debugging-port=$port","--user-data-dir=$profile",$InitialUrl
    )
    $proc = Start-Process -FilePath $Browser -ArgumentList $args -PassThru -WindowStyle Hidden

    try {
        $targets = $null
        for ($i=0; $i -lt 80; $i++) {
            Start-Sleep -Milliseconds 500
            try {
                $targets = Invoke-RestMethod "http://127.0.0.1:$port/json"
                if ($targets) { break }
            } catch {}
        }
        if (-not $targets) { throw "Could not connect to the browser debugging interface." }

        $target = $targets | Where-Object { $_.type -eq "page" } | Select-Object -First 1
        if (-not $target.webSocketDebuggerUrl) { throw "No browser page target was found." }

        $ws = [System.Net.WebSockets.ClientWebSocket]::new()
        $ws.ConnectAsync([Uri]$target.webSocketDebuggerUrl,[Threading.CancellationToken]::None).GetAwaiter().GetResult()

        $payload = @{
            id = 1
            method = "Runtime.evaluate"
            params = @{
                expression = $Expression
                awaitPromise = $true
                returnByValue = $true
            }
        } | ConvertTo-Json -Depth 8 -Compress

        $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
        $ws.SendAsync(
            [ArraySegment[byte]]::new($bytes),
            [Net.WebSockets.WebSocketMessageType]::Text,
            $true,
            [Threading.CancellationToken]::None
        ).GetAwaiter().GetResult()

        $buffer = New-Object byte[] 16777216
        $ms = New-Object IO.MemoryStream
        do {
            $r = $ws.ReceiveAsync(
                [ArraySegment[byte]]::new($buffer),
                [Threading.CancellationToken]::None
            ).GetAwaiter().GetResult()
            $ms.Write($buffer,0,$r.Count)
        } until ($r.EndOfMessage)

        $json = [Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
        $ws.Dispose()

        if ($json.result.exceptionDetails) {
            throw $json.result.exceptionDetails.text
        }

        return $json.result.result.value
    }
    finally {
        if ($proc -and -not $proc.HasExited) {
            Stop-Process $proc.Id -Force -ErrorAction SilentlyContinue
        }
        Remove-Item $profile -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-LinksFromRawPaldeckHtml {
    param([Parameter(Mandatory)][string]$Html)

    $results = New-Object Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)

    # Decode common forms used inside Next.js/React serialized payloads.
    $variants = @(
        $Html,
        [Net.WebUtility]::HtmlDecode($Html),
        ($Html -replace '\\u002F','/' -replace '\\/','/' -replace '&quot;','"')
    )

    foreach ($text in $variants) {
        foreach ($pattern in @(
            '(?i)https://(?:www\.)?paldeck\.cc/items/([A-Za-z0-9_]+)',
            '(?i)["'']?/items/([A-Za-z0-9_]+)',
            '(?i)href\\?["'']?\s*[:=]\s*\\?["''](?:https://(?:www\.)?paldeck\.cc)?/items/([A-Za-z0-9_]+)',
            '(?i)asset(?:Name|_name|Id|ID)\\?["'']?\s*[:=]\s*\\?["'']([A-Za-z][A-Za-z0-9_]{1,149})'
        )) {
            foreach ($match in [regex]::Matches($text,$pattern)) {
                $asset = $match.Groups[1].Value
                if ($asset -match '^[A-Za-z][A-Za-z0-9_]{0,149}$') {
                    [void]$results.Add("https://paldeck.cc/items/$asset")
                }
            }
        }
    }

    return @($results | Sort-Object)
}

function Get-PaldeckItemLinks {
    param([string]$Browser)

    $allLinks = New-Object Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    $discoveryNotes = New-Object Collections.Generic.List[string]

    Write-Host "Reading the complete Paldeck HTML/application payload..." -ForegroundColor White
    try {
        $response = Invoke-WebRequest `
            -UseBasicParsing `
            -Uri $PaldeckUrl `
            -TimeoutSec 60 `
            -Headers @{
                "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Aegis-Palworld-Suite/2.3"
                "Accept-Language" = "en-US,en;q=0.9"
                "Cache-Control" = "no-cache"
            }

        $rawLinks = @(Get-LinksFromRawPaldeckHtml -Html ([string]$response.Content))
        foreach ($link in $rawLinks) { [void]$allLinks.Add($link) }
        $discoveryNotes.Add("Raw HTML / embedded application data: $($rawLinks.Count)")
    }
    catch {
        $discoveryNotes.Add("Raw HTML discovery failed: $($_.Exception.Message)")
    }

    Write-Host "Scanning Paldeck sitemaps and the fully rendered item database..." -ForegroundColor White
    $script = @'
(async () => {
  const found = new Set();
  const notes = [];
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

  function addAsset(value) {
    if (!value) return;
    try {
      let text = String(value)
        .replaceAll('\\u002F','/')
        .replaceAll('\\/','/');

      const absolute = [...text.matchAll(/https:\/\/(?:www\.)?paldeck\.cc\/items\/([A-Za-z][A-Za-z0-9_]{0,149})/gi)];
      const relative = [...text.matchAll(/\/items\/([A-Za-z][A-Za-z0-9_]{0,149})/gi)];
      const assetFields = [...text.matchAll(/asset(?:Name|_name|Id|ID)["']?\s*[:=]\s*["']([A-Za-z][A-Za-z0-9_]{1,149})/gi)];

      for (const m of absolute) found.add('https://paldeck.cc/items/' + m[1]);
      for (const m of relative) found.add('https://paldeck.cc/items/' + m[1]);
      for (const m of assetFields) found.add('https://paldeck.cc/items/' + m[1]);
    } catch {}
  }

  function collectEverythingVisibleAndSerialized() {
    document.querySelectorAll('a[href]').forEach(a => addAsset(a.href));
    document.querySelectorAll('script').forEach(s => addAsset(s.textContent || ''));
    addAsset(document.documentElement.outerHTML);

    try {
      if (Array.isArray(self.__next_f)) {
        self.__next_f.forEach(chunk => addAsset(JSON.stringify(chunk)));
      }
    } catch {}

    try {
      for (const key of Object.keys(self)) {
        if (!/^__NEXT|^__next|paldeck|item/i.test(key)) continue;
        try { addAsset(JSON.stringify(self[key])); } catch {}
      }
    } catch {}
  }

  async function readSitemap(url, depth = 0) {
    if (depth > 4) return;
    try {
      const response = await fetch(url, {cache:'no-store'});
      if (!response.ok) return;
      const xml = await response.text();
      const locs = [...xml.matchAll(/<loc>\s*([^<]+)\s*<\/loc>/gi)].map(m => m[1].trim());

      for (const loc of locs) {
        if (/\/items\/[A-Za-z0-9_]+/i.test(loc)) addAsset(loc);
        else if (/sitemap/i.test(loc)) await readSitemap(loc, depth + 1);
      }
    } catch {}
  }

  for (const sitemap of [
    '/sitemap.xml',
    '/sitemap-index.xml',
    '/sitemap_index.xml',
    '/items-sitemap.xml',
    '/sitemap-items.xml'
  ]) {
    await readSitemap(location.origin + sitemap);
  }

  async function exhaustPage() {
    let stable = 0;
    let previous = -1;

    for (let i = 0; i < 240; i++) {
      collectEverythingVisibleAndSerialized();

      window.scrollTo(0, document.documentElement.scrollHeight);
      document.querySelectorAll('*').forEach(el => {
        try {
          const style = getComputedStyle(el);
          if ((style.overflowY === 'auto' || style.overflowY === 'scroll') &&
              el.scrollHeight > el.clientHeight) {
            el.scrollTop = el.scrollHeight;
          }
        } catch {}
      });

      const more = [...document.querySelectorAll('button,[role="button"],a')]
        .find(el => /load(ing)? more|show more|view more/i.test((el.textContent || '').trim()) &&
                    el.offsetParent !== null);
      if (more) {
        try {
          more.scrollIntoView({block:'center'});
          more.click();
        } catch {}
      }

      window.dispatchEvent(new Event('scroll'));
      document.dispatchEvent(new Event('scroll'));
      await sleep(700);
      collectEverythingVisibleAndSerialized();

      if (found.size === previous) stable++;
      else stable = 0;
      previous = found.size;

      if (stable >= 14) break;
    }
  }

  async function selectOptionByText(text) {
    let changed = false;

    for (const select of [...document.querySelectorAll('select')]) {
      const option = [...select.options].find(o => (o.textContent || '').trim() === text);
      if (!option) continue;
      select.value = option.value;
      select.dispatchEvent(new Event('input', {bubbles:true}));
      select.dispatchEvent(new Event('change', {bubbles:true}));
      changed = true;
      await sleep(600);
    }

    if (changed) return true;

    const trigger = [...document.querySelectorAll('button,[role="combobox"],[aria-haspopup="listbox"]')]
      .find(el => {
        const value = (el.textContent || '').trim();
        return /All Categories|Ascending|Descending|Sort/i.test(value) && el.offsetParent !== null;
      });

    if (trigger) {
      try {
        trigger.click();
        await sleep(250);
        const option = [...document.querySelectorAll('[role="option"],button,li,div')]
          .find(el => (el.textContent || '').trim() === text && el.offsetParent !== null);
        if (option) {
          option.click();
          await sleep(700);
          return true;
        }
      } catch {}
    }

    return false;
  }

  collectEverythingVisibleAndSerialized();
  await exhaustPage();

  const categories = [
    'All Categories','Materials','Pal Sphere','Ammo','Dev Items','Consumables',
    'Weapons','Essential','Armor','Accessories','Other','Food','Pal Summon','Boss Reward'
  ];

  for (const category of categories) {
    await selectOptionByText(category);
    window.scrollTo(0,0);
    await sleep(300);

    for (const direction of ['Ascending','Descending']) {
      await selectOptionByText(direction);
      await exhaustPage();
    }
  }

  // Capture URLs from any JSON/XHR resources observed by the page.
  try {
    const resourceUrls = performance.getEntriesByType('resource')
      .map(entry => entry.name)
      .filter(url => /item|api|data|json/i.test(url));

    for (const url of [...new Set(resourceUrls)]) {
      try {
        const response = await fetch(url, {cache:'no-store'});
        const type = response.headers.get('content-type') || '';
        if (!response.ok || !/json|text|javascript/i.test(type)) continue;
        addAsset(await response.text());
      } catch {}
    }
  } catch {}

  collectEverythingVisibleAndSerialized();
  return [...found].sort();
})()
'@

    try {
        $browserLinks = @(
            Invoke-CdpExpression `
                -Browser $Browser `
                -InitialUrl $PaldeckUrl `
                -Expression $script
        ) | ForEach-Object { [string]$_ } |
            Where-Object { $_ -match '^https://paldeck\.cc/items/[A-Za-z][A-Za-z0-9_]{0,149}$' } |
            Sort-Object -Unique

        foreach ($link in $browserLinks) { [void]$allLinks.Add($link) }
        $discoveryNotes.Add("Browser, sitemap, rendered DOM, Next.js payload and resources: $($browserLinks.Count)")
    }
    catch {
        $discoveryNotes.Add("Browser discovery failed: $($_.Exception.Message)")
    }

    # Preserve every valid record already known locally. A site layout change must
    # never silently delete previously imported Asset IDs.
    if (Test-Path $DataFile) {
        try {
            $existing = [IO.File]::ReadAllText($DataFile) | ConvertFrom-Json
            $existingLinks = @(
                $existing.records |
                Where-Object { $_.id -match '^[A-Za-z][A-Za-z0-9_]{0,149}$' } |
                ForEach-Object { "https://paldeck.cc/items/$($_.id)" }
            )
            foreach ($link in $existingLinks) { [void]$allLinks.Add($link) }
            $discoveryNotes.Add("Existing verified local Asset IDs retained: $($existingLinks.Count)")
        }
        catch {
            $discoveryNotes.Add("Existing database merge failed: $($_.Exception.Message)")
        }
    }

    # Known-current validation seeds. These are not substituted records; every
    # URL is still fetched and parsed directly from Paldeck.
    foreach ($asset in @(
        'WorldTreeIngot',
        'WorldTreeOre',
        'Money',
        'CopperIngot',
        'IronIngot'
    )) {
        [void]$allLinks.Add("https://paldeck.cc/items/$asset")
    }

    Write-Host ""
    foreach ($note in $discoveryNotes) {
        Write-Host "  $note" -ForegroundColor DarkGray
    }
    Write-Host "  Combined unique Paldeck item pages: $($allLinks.Count)" -ForegroundColor Cyan
    Write-Host ""

    return @($allLinks | Sort-Object)
}

function Convert-HtmlToText {
    param([string]$Html)

    $withoutScript = [regex]::Replace(
        $Html,
        '(?is)<(script|style|noscript)\b[^>]*>.*?</\1>',
        "`n"
    )
    $withLines = [regex]::Replace($withoutScript, '(?i)<br\s*/?>|</p>|</div>|</h[1-6]>', "`n")
    $plain = [regex]::Replace($withLines, '<[^>]+>', '')
    $plain = [Net.WebUtility]::HtmlDecode($plain)
    return [regex]::Replace($plain, '[ \t]+', ' ')
}

function Get-PageDescription { param([string]$Html,[string]$PlainText) $values=New-Object Collections.Generic.List[string]; foreach($p in @('(?is)<meta[^>]+name=["'']description["''][^>]+content=["'']([^"'']+)["'']','(?is)<meta[^>]+property=["'']og:description["''][^>]+content=["'']([^"'']+)["'']','(?is)"description"\s*:\s*"((?:\\.|[^"\\])*)"')){foreach($m in [regex]::Matches($Html,$p)){$v=$m.Groups[1].Value;try{if($p -match '"description"'){$v=('"'+$v+'"')|ConvertFrom-Json}}catch{};$v=Convert-HtmlToText -Html $v;if($v){$values.Add($v)}}}; if($PlainText){$m=[regex]::Match($PlainText,'(?im)^\s*Description\s*$\s*^([^\r\n]{12,700})\s*$');if($m.Success){$values.Add($m.Groups[1].Value.Trim())}}; return [string]($values|Where-Object{$_.Length-ge12-and$_.Length-le700-and$_-notmatch '^Paldeck|^Find information|^Explore Palworld|^Palworld database'}|Sort-Object Length|Select-Object -First 1)}

function Get-FieldAfterLabel {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Label,
        [string]$Pattern = '[^\r\n]+'
    )

    $match = [regex]::Match(
        $Text,
        "(?im)^\s*" + [regex]::Escape($Label) + "\s*$\s*^($Pattern)\s*$"
    )
    if ($match.Success) { return $match.Groups[1].Value.Trim() }
    return $null
}

function Get-NumericFieldAfterLabel {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Label
    )

    $value = Get-FieldAfterLabel -Text $Text -Label $Label -Pattern '-?[0-9]+(?:\.[0-9]+)?'
    if ($null -eq $value) { return $null }

    $number = 0.0
    if ([double]::TryParse(
        $value,
        [Globalization.NumberStyles]::Any,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$number
    )) {
        return $number
    }

    return $null
}

function Get-PaldeckRecords {
    param([string[]]$Links)

    $records = [Collections.Generic.List[object]]::new()
    $failures = [Collections.Generic.List[string]]::new()
    $index = 0

    foreach ($url in ($Links | Sort-Object -Unique)) {
        $index++
        try {
            $response = Invoke-WebRequest `
                -UseBasicParsing `
                -Uri $url `
                -TimeoutSec 45 `
                -MaximumRedirection 8 `
                -Headers @{
                    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Aegis-Palworld-Suite/2.3"
                    "Accept-Language" = "en-US,en;q=0.9"
                    "Cache-Control" = "no-cache"
                }

            $html = [string]$response.Content
            $plain = Convert-HtmlToText -Html $html

            $asset = Get-FieldAfterLabel -Text $plain -Label "Asset Name" -Pattern '[A-Za-z][A-Za-z0-9_]{0,149}'
            if (-not $asset) {
                $asset = ([Uri]$response.BaseResponse.ResponseUri).Segments[-1].TrimEnd("/")
                $asset = [Uri]::UnescapeDataString($asset)
            }

            $category = Get-FieldAfterLabel -Text $plain -Label "Category" -Pattern '[A-Za-z][A-Za-z /&-]{0,80}'
            $typeA = Get-FieldAfterLabel -Text $plain -Label "Type A" -Pattern '[^\r\n]{1,150}'
            $typeB = Get-FieldAfterLabel -Text $plain -Label "Type B" -Pattern '[^\r\n]{1,150}'
            $rank = Get-NumericFieldAfterLabel -Text $plain -Label "Rank"
            $rarity = Get-NumericFieldAfterLabel -Text $plain -Label "Rarity"
            $price = Get-NumericFieldAfterLabel -Text $plain -Label "Price"
            $weight = Get-NumericFieldAfterLabel -Text $plain -Label "Weight"
            $stackSize = Get-NumericFieldAfterLabel -Text $plain -Label "Stack Size"

            $displayName = $null
            $h1 = [regex]::Match($html, '(?is)<h1\b[^>]*>(.*?)</h1>')
            if ($h1.Success) {
                $displayName = [Net.WebUtility]::HtmlDecode(
                    [regex]::Replace($h1.Groups[1].Value, '<[^>]+>', '')
                ).Trim()
            }

            if (-not $displayName) {
                $title = [regex]::Match($html, '(?is)<title\b[^>]*>(.*?)</title>')
                if ($title.Success) {
                    $displayName = [Net.WebUtility]::HtmlDecode(
                        [regex]::Replace($title.Groups[1].Value, '\s*[|\-]\s*Paldeck.*$','')
                    ).Trim()
                }
            }

            if (-not $displayName) { $displayName = $asset }

            $description = Get-PageDescription -Html $html -PlainText $plain

            $paldeckNumber = $null
            $numberMatch = [regex]::Match($plain, '(?m)^\s*#([0-9]+)\s*$')
            if ($numberMatch.Success) { $paldeckNumber = [int]$numberMatch.Groups[1].Value }

            if ($asset -match '^[A-Za-z][A-Za-z0-9_]{0,149}$' -and
                $displayName -and
                $html -match '(?i)Asset Name') {

                $records.Add([pscustomobject]@{
                    id = [string]$asset
                    name = [string]$displayName
                    source = "Paldeck"
                    category = $(if ($category) { [string]$category } else { "Item" })
                    page = "https://paldeck.cc/items/$asset"
                    description = $(if ($description) { [string]$description } else { "" })
                    paldeckNumber = $paldeckNumber
                    typeA = $typeA
                    typeB = $typeB
                    rank = $rank
                    rarity = $rarity
                    price = $price
                    weight = $weight
                    stackSize = $stackSize
                })
            }
            else {
                $failures.Add("$url | Paldeck item fields were not found")
            }
        }
        catch {
            $failures.Add("$url | $($_.Exception.Message)")
        }

        if (($index % 25) -eq 0 -or $index -eq $Links.Count) {
            Write-Host (
                "Parsed {0}/{1} pages | Valid: {2} | Failed: {3}" -f
                $index,$Links.Count,$records.Count,$failures.Count
            ) -ForegroundColor DarkGray
        }
    }

    $script:PaldeckImportFailures = @($failures)
    return $records
}

function Initialize-IconCache {
    New-Item -ItemType Directory -Path $IconDirectory -Force | Out-Null

    if (-not (Test-Path $FallbackIcon)) {
        throw "WPF-compatible fallback image is missing: $FallbackIcon"
    }
}
function Test-ImageFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    $item = Get-Item $Path
    if ($item.Length -lt 100) { return $false }

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 12) {
        $header = [Text.Encoding]::ASCII.GetString($bytes,0,[Math]::Min(12,$bytes.Length))
        if ($header.StartsWith("RIFF") -and $header.Contains("WEBP")) { return $true }
    }
    return $false
}

function Get-PageIconCandidates {
    param([string]$PageUrl)

    if (-not $PageUrl) { return @() }

    try {
        $response = Invoke-WebRequest `
            -UseBasicParsing `
            -Uri $PageUrl `
            -TimeoutSec 25 `
            -Headers @{
                "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Aegis-Palworld-Suite"
                "Accept-Language" = "en-US,en;q=0.9"
            }

        $html = [string]$response.Content
        $results = New-Object Collections.Generic.List[string]

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
                if ($value -match '^https?://') { $results.Add($value) }
            }
        }

        return @($results | Sort-Object -Unique)
    }
    catch {
        return @()
    }
}

function Get-LocalIcon {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Page
    )

    $safeId = $Id -replace '[^A-Za-z0-9_]', '_'
    $relativePath = "Icons/$safeId.webp"
    $localPath = Join-Path $IconDirectory "$safeId.webp"

    if (Test-ImageFile $localPath) { return $relativePath }

    $urls = New-Object Collections.Generic.List[string]
    $urls.Add("https://api.paldeck.cc/assets/palworld/items/T_itemicon_$Id.webp")
    $urls.Add("https://paldeck.cc/assets/palworld/items/T_itemicon_$Id.webp")

    foreach ($candidate in (Get-PageIconCandidates -PageUrl $Page)) {
        if (-not $urls.Contains($candidate)) { $urls.Add($candidate) }
    }

    foreach ($iconUrl in $urls) {
        try {
            Invoke-WebRequest `
                -UseBasicParsing `
                -Uri $iconUrl `
                -OutFile $localPath `
                -TimeoutSec 25 `
                -Headers @{
                    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Aegis-Palworld-Suite"
                    "Accept" = "image/webp,image/*,*/*;q=0.8"
                    "Referer" = "https://paldeck.cc/"
                }

            if (Test-ImageFile $localPath) { return $relativePath }
        }
        catch {}

        Remove-Item $localPath -Force -ErrorAction SilentlyContinue
    }

    return "Icons/_fallback.png"
}

function Cache-RecordIcons {
    param([object[]]$Records)

    Initialize-IconCache
    $total = @($Records).Count
    $downloaded = 0
    $fallbacks = 0
    $index = 0

    foreach ($record in $Records) {
        $index++
        $record.icon = Get-LocalIcon -Id $record.id -Page $record.page

        if ($record.icon -eq "Icons/_fallback.png") {
            $fallbacks++
        }
        else {
            $downloaded++
        }

        if (($index % 25) -eq 0 -or $index -eq $total) {
            Write-Host "Cached icons for $index of $total records..." -ForegroundColor DarkGray
        }
    }

    return [pscustomobject]@{
        Downloaded = $downloaded
        Fallbacks = $fallbacks
    }
}

function Escape-SqlLiteral {
    param([object[]]$Records)

    Initialize-IconCache
    $total = @($Records).Count
    $downloaded = 0
    $fallbacks = 0
    $index = 0

    foreach ($record in $Records) {
        $index++
        $record.icon = Get-LocalIcon -Id $record.id
        if ($record.icon -eq "Icons/_fallback.png") { $fallbacks++ } else { $downloaded++ }

        if (($index % 25) -eq 0 -or $index -eq $total) {
            Write-Host "Cached icons for $index of $total records..." -ForegroundColor DarkGray
        }
    }

    return [pscustomobject]@{ Downloaded=$downloaded; Fallbacks=$fallbacks }
}

function Escape-SqlLiteral {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return "NULL" }
    return "'" + $Value.Replace("'","''") + "'"
}

function Write-Database {
    param([object[]]$Records)

    $map = @{}
    foreach ($r in $Records) {
        if (-not $r.id) { continue }
        $key = ([string]$r.id).ToLowerInvariant()

        if ($r.id -match '^[A-Za-z0-9_]+$' -and -not $map.ContainsKey($key)) {
            $map[$key] = [pscustomobject]@{
                id = [string]$r.id
                name = [string]$r.name
                source = "Paldeck"
                category = [string]$r.category
                page = [string]$r.page
                description = $(if ($r.description) { [string]$r.description } else { "" })
                paldeckNumber = $r.paldeckNumber
                typeA = [string]$r.typeA
                typeB = [string]$r.typeB
                rank = $r.rank
                rarity = $r.rarity
                price = $r.price
                weight = $r.weight
                stackSize = $r.stackSize
                command = "!giveme $($r.id):9999"
                icon = "Icons/_fallback.png"
            }
        }
    }

    $sorted = @($map.Values | Sort-Object id)
    if ($sorted.Count -lt $MinimumRecordCount) {
        throw "Only $($sorted.Count) verified records were produced; minimum is $MinimumRecordCount."
    }

    $requiredItems = @(
        @{ Name = "Gold Coin"; AssetId = "Money" },
        @{ Name = "Ingot"; AssetId = "CopperIngot" },
        @{ Name = "Refined Ingot"; AssetId = "IronIngot" },
        @{ Name = "Paloxite Ingot"; AssetId = "WorldTreeIngot" }
    )

    foreach ($required in $requiredItems) {
        $match = $sorted | Where-Object {
            $_.id -eq $required.AssetId
        } | Select-Object -First 1

        if (-not $match) {
            throw "Required item missing: $($required.Name) = $($required.AssetId)"
        }
    }

    if ($SkipIcons) {
        Initialize-IconCache
        $iconStats = [pscustomobject]@{ Downloaded = 0; Fallbacks = $sorted.Count }
    }
    else {
        Write-Host "Downloading and validating item icons..." -ForegroundColor White
        $iconStats = Cache-RecordIcons -Records $sorted
    }

    $generatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $databaseObject = [ordered]@{
        schemaVersion = 2
        generatedAt = $generatedAt
        source = $PaldeckUrl
        count = $sorted.Count
        records = $sorted
    }

    $stageJson = Join-Path $StagingDirectory "items.json"
    $stageJs = Join-Path $StagingDirectory "data.js"
    $stageCommands = Join-Path $StagingDirectory "commands.txt"
    $stageAudit = Join-Path $StagingDirectory "audit.txt"
    $stageSql = Join-Path $StagingDirectory "database.sql"

    $json = $databaseObject | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($stageJson,$json,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($stageJs,"window.PALWORLD_DATA=" + ($databaseObject | ConvertTo-Json -Depth 8 -Compress) + ";",[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllLines($stageCommands,@($sorted | ForEach-Object command),[Text.UTF8Encoding]::new($false))

    $audit = @(
        "Aegis Palworld Suite Database Audit",
        "====================================",
        "Schema version: 2",
        "Generated: $generatedAt",
        "Verified Paldeck records: $($sorted.Count)",
        "Validated icons: $($iconStats.Downloaded)",
        "Fallback icons: $($iconStats.Fallbacks)",
        "Descriptions present: $(@($sorted | Where-Object description).Count)",
        "Records with Paldeck numeric ID: $(@($sorted | Where-Object { $null -ne $_.paldeckNumber }).Count)",
        "Records with properties: $(@($sorted | Where-Object { $null -ne $_.stackSize }).Count)",
        "Failed or invalid pages: $(@($script:PaldeckImportFailures).Count)",
        "Validation: Gold Coin = Money",
        "Validation: Ingot = CopperIngot",
        "Validation: Refined Ingot = IronIngot",
        "Validation: Paloxite Ingot = WorldTreeIngot",
        "Source: $PaldeckUrl",
        "",
        "Failed pages:",
        $(@($script:PaldeckImportFailures) -join "`r`n")
    )
    [IO.File]::WriteAllLines($stageAudit,$audit,[Text.UTF8Encoding]::new($false))

    $sql = New-Object Collections.Generic.List[string]
    $sql.Add("PRAGMA journal_mode=WAL;")
    $sql.Add("BEGIN TRANSACTION;")
    $sql.Add("DROP TABLE IF EXISTS metadata;")
    $sql.Add("DROP TABLE IF EXISTS items;")
    $sql.Add("CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
    $sql.Add("CREATE TABLE items (asset_id TEXT PRIMARY KEY, name TEXT NOT NULL, category TEXT, command TEXT NOT NULL, page_url TEXT, icon_path TEXT, description TEXT);")
    $sql.Add("CREATE INDEX idx_items_name ON items(name);")
    $sql.Add("CREATE INDEX idx_items_category ON items(category);")
    $sql.Add("INSERT INTO metadata(key,value) VALUES ('schema_version','2');")
    $sql.Add("INSERT INTO metadata(key,value) VALUES ('generated_at'," + (Escape-SqlLiteral $generatedAt) + ");")
    $sql.Add("INSERT INTO metadata(key,value) VALUES ('source'," + (Escape-SqlLiteral $PaldeckUrl) + ");")
    $sql.Add("INSERT INTO metadata(key,value) VALUES ('record_count'," + (Escape-SqlLiteral ([string]$sorted.Count)) + ");")

    foreach ($r in $sorted) {
        $sql.Add(
            "INSERT INTO items(asset_id,name,category,command,page_url,icon_path,description) VALUES (" +
            (Escape-SqlLiteral $r.id) + "," +
            (Escape-SqlLiteral $r.name) + "," +
            (Escape-SqlLiteral $r.category) + "," +
            (Escape-SqlLiteral $r.command) + "," +
            (Escape-SqlLiteral $r.page) + "," +
            (Escape-SqlLiteral $r.icon) + "," +
            (Escape-SqlLiteral $r.description) + ");"
        )
    }
    $sql.Add("COMMIT;")
    [IO.File]::WriteAllLines($stageSql,$sql,[Text.UTF8Encoding]::new($false))

    # Atomic publish: no partial database is ever exposed to the Suite.
    Move-Item $stageJson $DataFile -Force
    Move-Item $stageJs $DataJsFile -Force
    Move-Item $stageCommands $CommandFile -Force
    Move-Item $stageAudit $AuditFile -Force
    Move-Item $stageSql $SqlFile -Force

    # Build SQLite when sqlite3.exe is available. JSON remains the guaranteed
    # compatibility snapshot for Windows PowerShell 5.1.
    $sqliteExeCandidates = @(
        (Join-Path $EngineRoot "sqlite3.exe"),
        (Join-Path $Root "Tools\sqlite3.exe")
    )
    $sqliteExe = $sqliteExeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($sqliteExe) {
        Remove-Item $SqliteFile -Force -ErrorAction SilentlyContinue
        Get-Content $SqlFile -Raw | & $sqliteExe $SqliteFile
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "SQLite creation failed, but the verified JSON database was published successfully."
        }
        else {
            Write-Host "SQLite database created: $SqliteFile" -ForegroundColor Green
        }
    }
    else {
        Write-Host "sqlite3.exe not bundled; SQL import script created for optional SQLite generation." -ForegroundColor DarkYellow
    }

    return $sorted.Count
}

Write-Host ""
Write-Host "Aegis Palworld Suite 2.0 Database Engine" -ForegroundColor Cyan
Write-Host "Building a verified Paldeck-only database..." -ForegroundColor White

$exitCode = 0
try {
    $browser = Find-Browser
    Write-Host "Using browser: $browser" -ForegroundColor Gray

    Write-Host "Discovering all Paldeck item pages..." -ForegroundColor White
    $links = @(Get-PaldeckItemLinks -Browser $browser)
    Write-Host "Discovered $($links.Count) unique item pages." -ForegroundColor Green

    if ($links.Count -lt $MinimumRecordCount) {
        throw "Discovery returned only $($links.Count) pages; minimum is $MinimumRecordCount."
    }

    Write-Host "Opening each page and reading its actual Asset Name..." -ForegroundColor White
    $records = @(Get-PaldeckRecords -Links $links)
    Write-Host "Parsed $($records.Count) candidate records." -ForegroundColor Green

    $count = Write-Database -Records $records
    Write-Host ""
    Write-Host "SUCCESS: Published $count verified items." -ForegroundColor Green
    Write-Host "Database: $DataFile" -ForegroundColor Gray
    Write-Host "Audit:    $AuditFile" -ForegroundColor Gray
}
catch {
    $exitCode = 1
    Write-Host ""
    Write-Host "DATABASE UPDATE FAILED" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""
    if (Test-Path $DataFile) {
        Write-Host "The existing verified database was preserved." -ForegroundColor Yellow
    }
    else {
        Write-Host "No verified database is installed yet." -ForegroundColor Yellow
    }
}
finally {
    try { Stop-Transcript | Out-Null } catch {}
}

exit $exitCode
