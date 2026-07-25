#requires -Version 5.1

Add-Type -AssemblyName PresentationFramework

function Show-LauncherError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    [System.Windows.MessageBox]::Show(
        $Message,
        'Aegis Palworld Suite',
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    ) | Out-Null
}

try {
    # PS2EXE does not reliably populate $PSScriptRoot or
    # $MyInvocation.MyCommand.Path after compilation.
    # AppDomain.BaseDirectory resolves to the folder containing Launcher.exe.
    $Root = [System.AppDomain]::CurrentDomain.BaseDirectory

    if ([string]::IsNullOrWhiteSpace($Root)) {
        $ExecutablePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $Root = Split-Path -Parent $ExecutablePath
    }

    if ([string]::IsNullOrWhiteSpace($Root)) {
        throw 'Unable to determine the Launcher.exe directory.'
    }

    $Root = $Root.TrimEnd('\')
    $App = Join-Path -Path $Root -ChildPath 'App\Aegis-Palworld-Suite.ps1'
    $Engine = Join-Path -Path $Root -ChildPath 'Engine\Update-PaldeckDatabase.ps1'
    $LogDirectory = Join-Path -Path $Root -ChildPath 'Logs'
    $LogFile = Join-Path -Path $LogDirectory -ChildPath 'Launcher-Error.txt'
    $PowerShellExe = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'

    if (-not (Test-Path -LiteralPath $App -PathType Leaf)) {
        Show-LauncherError @"
The Aegis application script is missing.

Expected:
$App

Keep Launcher.exe in the Suite root beside the App, Engine,
Database, Icons, and Logs folders.
"@
        exit 1
    }

    if (-not (Test-Path -LiteralPath $Engine -PathType Leaf)) {
        Show-LauncherError @"
The Aegis database engine is missing.

Expected:
$Engine

Keep Launcher.exe in the Suite root folder.
"@
        exit 1
    }

    if (-not (Test-Path -LiteralPath $PowerShellExe -PathType Leaf)) {
        throw "Windows PowerShell was not found at: $PowerShellExe"
    }

    if (-not (Test-Path -LiteralPath $LogDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }

    Set-Location -LiteralPath $Root

    $ArgumentList = @(
        '-NoLogo'
        '-NoProfile'
        '-STA'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        "`"$App`""
    )

    $Process = Start-Process `
        -FilePath $PowerShellExe `
        -ArgumentList $ArgumentList `
        -WorkingDirectory $Root `
        -WindowStyle Hidden `
        -Wait `
        -PassThru

    if ($Process.ExitCode -ne 0) {
        $Message = @"
Aegis Palworld Suite exited with code $($Process.ExitCode).

Review:
$LogFile

Also review:
$(Join-Path -Path $LogDirectory -ChildPath 'Suite-Startup-Error.txt')
"@

        $Message | Set-Content -LiteralPath $LogFile -Encoding UTF8
        Show-LauncherError $Message
        exit $Process.ExitCode
    }

    exit 0
}
catch {
    $ErrorText = $_ | Out-String

    try {
        $FallbackRoot = [System.AppDomain]::CurrentDomain.BaseDirectory
        if (-not [string]::IsNullOrWhiteSpace($FallbackRoot)) {
            $FallbackLogDirectory = Join-Path -Path $FallbackRoot -ChildPath 'Logs'
            New-Item -ItemType Directory -Path $FallbackLogDirectory -Force | Out-Null
            $FallbackLogFile = Join-Path -Path $FallbackLogDirectory -ChildPath 'Launcher-Error.txt'
            $ErrorText | Set-Content -LiteralPath $FallbackLogFile -Encoding UTF8
        }
    }
    catch {
        # Avoid masking the original launcher error.
    }

    Show-LauncherError @"
Launcher failed to start.

$($_.Exception.Message)

Keep Launcher.exe in the Suite root beside the App and Engine folders.
"@

    exit 1
}
