# Copyright (C) Chemin-Neuf IT Team
# SPDX-License-Identifier: GPL-3.0-only
# Full license text: see LICENSE at the repository root
<#
.SYNOPSIS
    Sets Windows 11 default applications for file extensions and protocols.

.DESCRIPTION
    Reads a CSV configuration file listing file-extension-to-ProgID and
    protocol-to-ProgID associations, verifies each ProgID exists in the
    registry, and applies the defaults using SetUserFTA.
    SetUserFTA is resolved automatically: the cache path is checked first,
    then a download from the internet is attempted, then a copy from a
    network share. Results are logged to a logs\ subfolder next to the
    script, with fallback to %TEMP%.

.PARAMETER ConfigPath
    Path to the CSV configuration file.
    The file must have a header row with columns Association and ProgID.
    Lines starting with # are treated as comments and ignored.
    Defaults to default-applications.csv in the same directory as the script.

.PARAMETER SetUserFTAPath
    Optional path to an existing SetUserFTA.exe.
    When provided, the automatic resolution logic (cache / download / network)
    is skipped entirely.

.PARAMETER Verbosity
    Controls the amount of output written to the console.
    None     - no console output.
    Normal   - key steps and results only (default).
    Detailed - all steps including detail messages.

.PARAMETER LogVerbosity
    Controls the amount of output written to the log file.
    None     - no log file.
    Normal   - key steps and results only.
    Detailed - all steps including detail messages (default).

.PARAMETER Quiet
    Suppresses all console output. Takes priority over Verbosity.

.PARAMETER Version
    Displays the script name and version, then exits.

.EXAMPLE
    .\set-default-applications.ps1

    Runs with the default configuration file (default-applications.csv).

.EXAMPLE
    .\set-default-applications.ps1 -ConfigPath "C:\IT\my-defaults.csv"

    Runs with a custom configuration file.

.EXAMPLE
    .\set-default-applications.ps1 -Verbosity Detailed -LogVerbosity Normal

    Runs with full console output but reduced log verbosity.

.NOTES
    File:           set-default-applications.ps1
    Version:        1.0.0
    Author:         Claude Sonnet 4.6 (GitHub Copilot)
    License:        GPL-3.0-only
    Prerequisites:  PowerShell 5.1+; no administrator rights required
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath = '',

    [Parameter()]
    [string]$SetUserFTAPath = '',

    [Parameter()]
    [ValidateSet('None', 'Normal', 'Detailed')]
    [string]$Verbosity = 'Normal',

    [Parameter()]
    [ValidateSet('None', 'Normal', 'Detailed')]
    [string]$LogVerbosity = 'Detailed',

    [Parameter()]
    [switch]$Quiet,

    [Parameter()]
    [switch]$Version
)

# ============================================================
# VERSION
# ============================================================
$scriptVersion = '1.0.0'
if ($Version) {
    Write-Host ('set-default-applications.ps1  v{0}' -f $scriptVersion)
    exit 0
}

# ============================================================
# CONFIGURATION
# ============================================================
$setUserFTACachePath   = 'C:\Support\SetUserFTA.exe'
$setUserFTADownloadUrl = 'https://setuserfta.com/SetUserFTA.zip'
$setUserFTANetworkPath = '\\your-server\your-share\SetUserFTA.exe'

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $PSScriptRoot 'default-applications.csv'
}

# ============================================================
# GLOBALS
# ============================================================
if ($Quiet) { $Verbosity = 'None' }
$Global:ConsoleVerbosity = $Verbosity
$Global:LogVerbosity     = $LogVerbosity

# ============================================================
# IMPORTS
# ============================================================
$sharedUtilsPath = Join-Path $PSScriptRoot 'SharedUtils.psm1'
if (-not (Test-Path $sharedUtilsPath)) {
    Write-Error ('SharedUtils.psm1 not found at: {0}' -f $sharedUtilsPath)
    exit 1
}
Import-Module $sharedUtilsPath -Force

# ============================================================
# LOGGING
# ============================================================
Initialize-Log -ScriptName 'set-default-applications' -Version $scriptVersion

# ============================================================
# FUNCTIONS
# ============================================================

<#
.SYNOPSIS
    Locates or obtains SetUserFTA.exe, caching it at the specified path.

.PARAMETER CachePath
    Target path where SetUserFTA.exe should be stored and reused.

.PARAMETER DownloadUrl
    URL to a ZIP archive containing SetUserFTA.exe.

.PARAMETER NetworkPath
    UNC path to a SetUserFTA.exe file used as a fallback if download fails.

.OUTPUTS
    Full path to SetUserFTA.exe if resolved, otherwise $null.
#>
function Resolve-SetUserFTA {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$CachePath,

        [Parameter(Mandatory=$true)]
        [string]$DownloadUrl,

        [Parameter(Mandatory=$true)]
        [string]$NetworkPath
    )

    # 1. Already cached
    if (Test-Path $CachePath) {
        Write-Detail ('SetUserFTA found at cache path: {0}' -f $CachePath)
        return $CachePath
    }

    # Determine a writable directory for the cache
    $cacheDir           = Split-Path $CachePath -Parent
    $effectiveCachePath = $CachePath

    try {
        if (-not (Test-Path $cacheDir)) {
            New-Item -ItemType Directory -Path $cacheDir -Force -ErrorAction Stop | Out-Null
        }
    }
    catch {
        $fallbackDir = Join-Path $env:LOCALAPPDATA 'SetUserFTA'
        Write-Warn ('Cannot create cache directory ''{0}'': {1}. Falling back to: {2}' -f $cacheDir, $_.Exception.Message, $fallbackDir)
        New-Item -ItemType Directory -Path $fallbackDir -Force -ErrorAction SilentlyContinue | Out-Null
        $effectiveCachePath = Join-Path $fallbackDir 'SetUserFTA.exe'
        $cacheDir           = $fallbackDir
    }

    # 2. Try downloading from the internet
    Write-Info ('Attempting to download SetUserFTA from: {0}' -f $DownloadUrl)
    $zipPath = Join-Path $env:TEMP 'SetUserFTA.zip'
    try {
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        Expand-Archive -Path $zipPath -DestinationPath $cacheDir -Force -ErrorAction Stop
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

        if (Test-Path $effectiveCachePath) {
            Write-Success ('SetUserFTA downloaded and extracted to: {0}' -f $effectiveCachePath)
            return $effectiveCachePath
        }

        # Zip may have extracted to a subfolder — search for the exe
        $found = Get-ChildItem -Path $cacheDir -Filter 'SetUserFTA.exe' -Recurse -ErrorAction SilentlyContinue |
                 Select-Object -First 1
        if ($found) {
            Write-Success ('SetUserFTA found after extraction at: {0}' -f $found.FullName)
            return $found.FullName
        }

        Write-Warn 'Download succeeded but SetUserFTA.exe was not found after extraction.'
    }
    catch {
        Write-Warn ('Download failed: {0}' -f $_.Exception.Message)
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    }

    # 3. Try copying from network path
    Write-Info ('Attempting to copy SetUserFTA from network: {0}' -f $NetworkPath)
    try {
        Copy-Item -Path $NetworkPath -Destination $effectiveCachePath -Force -ErrorAction Stop
        Write-Success ('SetUserFTA copied from network to: {0}' -f $effectiveCachePath)
        return $effectiveCachePath
    }
    catch {
        Write-Warn ('Network copy failed: {0}' -f $_.Exception.Message)
    }

    return $null
}

<#
.SYNOPSIS
    Tests whether a ProgID is registered on this machine.

.PARAMETER ProgID
    The ProgID to look up in HKLM or HKCU.
#>
function Test-ProgID {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ProgID
    )
    return (Test-Path ('HKLM:\SOFTWARE\Classes\{0}' -f $ProgID)) -or
           (Test-Path ('HKCU:\SOFTWARE\Classes\{0}'  -f $ProgID))
}

# ============================================================
# MAIN
# ============================================================
Write-Info ('set-default-applications.ps1 v{0} starting' -f $scriptVersion)
Write-Detail ('Log file: {0}' -f $Global:LogFile)

# Validate config file
if (-not (Test-Path $ConfigPath)) {
    Write-ErrorLog ('Config file not found: {0}' -f $ConfigPath)
    exit 1
}
Write-Info ('Using config file: {0}' -f $ConfigPath)

# Resolve SetUserFTA
$exePath = $SetUserFTAPath
if (-not $exePath) {
    $exePath = Resolve-SetUserFTA -CachePath $setUserFTACachePath `
                                   -DownloadUrl $setUserFTADownloadUrl `
                                   -NetworkPath $setUserFTANetworkPath
}

if (-not $exePath -or -not (Test-Path $exePath)) {
    Write-ErrorLog 'SetUserFTA.exe could not be found or obtained. Aborting.'
    exit 1
}
Write-Info ('Using SetUserFTA: {0}' -f $exePath)

# Read CSV, skipping comment and blank lines
$csvLines = Get-Content $ConfigPath |
            Where-Object { $_ -notmatch '^\s*#' -and $_ -match '\S' }

if (-not $csvLines) {
    Write-Warn 'No content found in config file after filtering comments. Nothing to do.'
    exit 0
}

$associations = $csvLines | ConvertFrom-Csv

if (-not $associations) {
    Write-Warn 'No associations found in config file. Nothing to do.'
    exit 0
}

$countSuccess = 0
$countWarning = 0
$countError   = 0

foreach ($row in $associations) {
    $association = $row.Association.Trim()
    $progID      = $row.ProgID.Trim()

    if (-not $association -or -not $progID) {
        Write-Warn 'Skipping row with empty Association or ProgID.'
        $countWarning++
        continue
    }

    Write-Detail ('Processing: {0} -> {1}' -f $association, $progID)

    # Verify ProgID exists in registry
    if (-not (Test-ProgID -ProgID $progID)) {
        Write-Warn ('ProgID ''{0}'' not found in registry — application may not be installed. Skipping ''{1}''.' -f $progID, $association)
        $countWarning++
        continue
    }

    # Apply the association
    $output   = & $exePath $association $progID 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0) {
        Write-Success ('Set: {0} -> {1}' -f $association, $progID)
        $countSuccess++
    }
    else {
        Write-ErrorLog ('Failed (exit code {0}): {1} -> {2}. Output: {3}' -f $exitCode, $association, $progID, ($output -join ' '))
        $countError++
    }
}

# Summary
Write-Info ('Completed. Success: {0} | Warnings: {1} | Errors: {2}' -f $countSuccess, $countWarning, $countError)

if ($countError -gt 0) {
    exit 1
}
exit 0
