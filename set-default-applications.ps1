# Copyright (C) Chemin-Neuf IT Team
# SPDX-License-Identifier: GPL-3.0-only
# Full license text: see LICENSE at the repository root
<#
.SYNOPSIS
    Sets Windows 11 default applications for file extensions and protocols.

.DESCRIPTION
    Reads a CSV configuration file listing file-extension-to-application and
    protocol-to-application associations, resolves the corresponding ProgID in
    the registry, and applies the defaults using SetUserFTA. Configuration can
    come either from one CSV file or from a TXT manifest listing multiple CSV
    files in the exact order they should be processed.
    SetUserFTA is resolved automatically: the cache path is checked first,
    then a download from the internet is attempted, then a copy from a
    network share. Results are logged to a logs\ subfolder next to the
    script, with fallback to %TEMP%.

.PARAMETER ConfigPath
    Path to the configuration input file.
    When ConfigType is CSV, ConfigPath must point to one CSV file with columns
    Association and Application.
    When ConfigType is TXT, ConfigPath must point to a TXT manifest containing
    one CSV path per line in processing order. Relative paths are resolved from
    the manifest file's directory.
    Lines starting with # are treated as comments and ignored.
    Defaults to default-applications.csv in the same directory as the script,
    or default-applications.txt when ConfigType is TXT.

.PARAMETER ConfigType
    Type of the configuration input file.
    CSV = one CSV file only.
    TXT = a manifest file listing multiple CSV files in order.

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
    .\set-default-applications.ps1 -ConfigType TXT -ConfigPath ".\default-applications.txt"

    Runs with a TXT manifest that lists multiple CSV files in order.

.EXAMPLE
    .\set-default-applications.ps1 -Verbosity Detailed -LogVerbosity Normal

    Runs with full console output but reduced log verbosity.

.NOTES
    File:           set-default-applications.ps1
    Version:        2.1.0
    Author:         Claude Sonnet 4.6 (GitHub Copilot)
    License:        GPL-3.0-only
    Prerequisites:  PowerShell 5.1+; no administrator rights required
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath = '',

    [Parameter()]
    [ValidateSet('CSV', 'TXT')]
    [string]$ConfigType = 'CSV',

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
$scriptVersion = '2.1.0'
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
    if ($ConfigType -eq 'TXT') {
        $ConfigPath = Join-Path $PSScriptRoot 'default-applications.txt'
    }
    else {
        $ConfigPath = Join-Path $PSScriptRoot 'default-applications.csv'
    }
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
    Resolves the full PowerShell registry path to an application's Capabilities subkey.
    Handles both relative paths (Software\...) and absolute paths (HKEY_LOCAL_MACHINE\...).
    Checks HKLM first, then HKCU.

.PARAMETER RawPath
    The path value stored in RegisteredApplications. May be relative or include a full
    HKEY_LOCAL_MACHINE / HKEY_CURRENT_USER prefix.
#>
function Resolve-CapabilitiesPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$RawPath
    )

    $normalizedPath = $RawPath
    if ($normalizedPath -match '^HKEY_LOCAL_MACHINE\\(.+)$') {
        $normalizedPath = 'HKLM:\' + $Matches[1]
    } elseif ($normalizedPath -match '^HKEY_CURRENT_USER\\(.+)$') {
        $normalizedPath = 'HKCU:\' + $Matches[1]
    }

    if ($normalizedPath -match '^HK[A-Z]+:\\') {
        if (Test-Path $normalizedPath) { return $normalizedPath }
        $wow64Path = $normalizedPath -replace '^(HKLM:\\SOFTWARE\\)(?!WOW6432Node)', '$1WOW6432Node\\'
        if ($wow64Path -ne $normalizedPath -and (Test-Path $wow64Path)) { return $wow64Path }
        return $null
    }

    $hklmPath = 'HKLM:\' + $normalizedPath
    if (Test-Path $hklmPath) { return $hklmPath }
    $hkcuPath = 'HKCU:\' + $normalizedPath
    if (Test-Path $hkcuPath) { return $hkcuPath }

    if ($normalizedPath -match '^Software\\(.+)$') {
        $wow64Path = 'HKLM:\SOFTWARE\WOW6432Node\' + $Matches[1]
        if (Test-Path $wow64Path) { return $wow64Path }
        $wow64PathHkcu = 'HKCU:\SOFTWARE\WOW6432Node\' + $Matches[1]
        if (Test-Path $wow64PathHkcu) { return $wow64PathHkcu }
    }

    return $null
}

<#
.SYNOPSIS
    Returns an ordered hashtable of all value names and data from a registry key.

.PARAMETER KeyPath
    Full registry path to the key.
#>
function Get-RegistryValues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$KeyPath
    )

    $key = Get-Item -Path $KeyPath -ErrorAction SilentlyContinue
    if (-not $key) { return [ordered]@{} }

    $result = [ordered]@{}
    foreach ($name in $key.GetValueNames()) {
        if ($name) {
            $result[$name] = $key.GetValue($name)
        }
    }

    return $result
}

<#
.SYNOPSIS
    Reads all registered application association declarations from the registry.

.OUTPUTS
    Hashtable keyed by application name. Each value contains FileAssociations and
    URLAssociations hashtables.
#>
function Get-RegisteredApplicationAssociations {
    [CmdletBinding()]
    param()

    $appsKey = Get-Item -Path 'HKLM:\SOFTWARE\RegisteredApplications' -ErrorAction SilentlyContinue
    if (-not $appsKey) {
        Write-ErrorLog 'HKLM:\SOFTWARE\RegisteredApplications not found.'
        return @{}
    }

    $applications = @{}
    foreach ($appName in ($appsKey.GetValueNames() | Where-Object { $_ } | Sort-Object)) {
        $capabilitiesRawPath = $appsKey.GetValue($appName)
        if (-not $capabilitiesRawPath) { continue }

        $capabilitiesPath = Resolve-CapabilitiesPath -RawPath $capabilitiesRawPath
        if (-not $capabilitiesPath) {
            Write-Detail ('Skipping application ''{0}'': capabilities path not found.' -f $appName)
            continue
        }

        $applications[$appName] = @{
            FileAssociations = Get-RegistryValues -KeyPath (Join-Path $capabilitiesPath 'FileAssociations')
            URLAssociations  = Get-RegistryValues -KeyPath (Join-Path $capabilitiesPath 'URLAssociations')
        }
    }

    return $applications
}

<#
.SYNOPSIS
    Resolves the declared ProgID for a specific association of a registered application.

.PARAMETER Association
    File extension (for example .pdf) or protocol (for example http).

.PARAMETER Application
    Registered application name exactly as listed under RegisteredApplications.

.PARAMETER ApplicationMap
    Hashtable returned by Get-RegisteredApplicationAssociations.
#>
function Resolve-ProgIDForApplicationAssociation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Association,

        [Parameter(Mandatory=$true)]
        [string]$Application,

        [Parameter(Mandatory=$true)]
        [hashtable]$ApplicationMap
    )

    if (-not $ApplicationMap.ContainsKey($Application)) {
        return $null
    }

    $associationMap = if ($Association.StartsWith('.')) {
        $ApplicationMap[$Application].FileAssociations
    } else {
        $ApplicationMap[$Application].URLAssociations
    }

    if ($associationMap.Contains($Association)) {
        return $associationMap[$Association]
    }

    return $null
}

<#
.SYNOPSIS
    Resolves the ordered list of CSV files to load from the selected config input.

.PARAMETER ConfigPath
    Path to either a CSV file or a TXT manifest.

.PARAMETER ConfigType
    Type of the configuration input file.
#>
function Resolve-ConfigCsvPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ConfigPath,

        [Parameter(Mandatory=$true)]
        [ValidateSet('CSV', 'TXT')]
        [string]$ConfigType
    )

    if (-not (Test-Path $ConfigPath)) {
        Write-ErrorLog ('Config file not found: {0}' -f $ConfigPath)
        return $null
    }

    $resolvedConfigPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigPath)
    $expectedExtension = if ($ConfigType -eq 'TXT') { '.txt' } else { '.csv' }
    $actualExtension = [System.IO.Path]::GetExtension($resolvedConfigPath)

    if ($actualExtension -ine $expectedExtension) {
        Write-ErrorLog ('ConfigType {0} requires a {1} file, but got: {2}' -f $ConfigType, $expectedExtension, $resolvedConfigPath)
        return $null
    }

    $csvPaths = [System.Collections.Generic.List[string]]::new()
    if ($ConfigType -eq 'CSV') {
        $csvPaths.Add($resolvedConfigPath)
        return $csvPaths
    }

    $manifestDir = Split-Path $resolvedConfigPath -Parent
    $manifestLines = Get-Content $resolvedConfigPath |
        Where-Object { $_ -notmatch '^\s*#' -and $_ -match '\S' }

    if (-not $manifestLines) {
        return $csvPaths
    }

    foreach ($line in $manifestLines) {
        $candidatePath = $line.Trim()
        if (-not [System.IO.Path]::IsPathRooted($candidatePath)) {
            $candidatePath = Join-Path $manifestDir $candidatePath
        }

        if ([System.IO.Path]::GetExtension($candidatePath) -ine '.csv') {
            Write-ErrorLog ('Manifest entry is not a CSV file: {0}' -f $line.Trim())
            return $null
        }

        if (-not (Test-Path $candidatePath)) {
            Write-ErrorLog ('CSV file listed in manifest not found: {0}' -f $candidatePath)
            return $null
        }

        $csvPaths.Add($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($candidatePath))
    }

    return $csvPaths
}

<#
.SYNOPSIS
    Loads association rows from one or more CSV files in order.

.PARAMETER CsvPaths
    Ordered list of CSV files to read.
#>
function Import-AssociationRows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string[]]$CsvPaths
    )

    $rows = [System.Collections.Generic.List[PSObject]]::new()
    foreach ($csvPath in $CsvPaths) {
        Write-Info ('Loading CSV file: {0}' -f $csvPath)

        $csvLines = Get-Content $csvPath |
            Where-Object { $_ -notmatch '^\s*#' -and $_ -match '\S' }

        if (-not $csvLines) {
            Write-Detail ('Skipping empty CSV file: {0}' -f $csvPath)
            continue
        }

        $csvRows = $csvLines | ConvertFrom-Csv
        if (-not $csvRows) {
            Write-Detail ('No association rows found in CSV file: {0}' -f $csvPath)
            continue
        }

        $propertyNames = $csvRows[0].PSObject.Properties.Name
        if (('Association' -notin $propertyNames) -or ('Application' -notin $propertyNames)) {
            Write-ErrorLog ('CSV file must contain Association and Application columns: {0}' -f $csvPath)
            return $null
        }

        foreach ($csvRow in $csvRows) {
            $rows.Add([PSCustomObject]@{
                Association = $csvRow.Association
                Application = $csvRow.Application
                SourcePath  = $csvPath
            })
        }
    }

    return $rows
}

# ============================================================
# MAIN
# ============================================================
Write-Info ('set-default-applications.ps1 v{0} starting' -f $scriptVersion)
Write-Detail ('Log file: {0}' -f $Global:LogFile)

$csvPaths = Resolve-ConfigCsvPaths -ConfigPath $ConfigPath -ConfigType $ConfigType
if ($null -eq $csvPaths) {
    exit 1
}

if ($csvPaths.Count -eq 0) {
    Write-Warn ('No CSV files found in config input: {0}' -f $ConfigPath)
    exit 0
}

Write-Info ('Using config input: {0} ({1})' -f $ConfigPath, $ConfigType)

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

$applicationMap = Get-RegisteredApplicationAssociations
if ($applicationMap.Count -eq 0) {
    Write-ErrorLog 'No registered applications could be resolved from the registry. Aborting.'
    exit 1
}

$associations = Import-AssociationRows -CsvPaths $csvPaths
if ($null -eq $associations) {
    exit 1
}

if (-not $associations -or $associations.Count -eq 0) {
    Write-Warn 'No associations found in the selected config input. Nothing to do.'
    exit 0
}

$countSuccess = 0
$countWarning = 0
$countError   = 0

foreach ($row in $associations) {
    $association = $row.Association.Trim()
    $application = $row.Application.Trim()

    if (-not $association -or -not $application) {
        Write-Warn 'Skipping row with empty Association or Application.'
        $countWarning++
        continue
    }

    $progID = Resolve-ProgIDForApplicationAssociation -Association $association -Application $application -ApplicationMap $applicationMap
    Write-Detail ('Processing: {0} -> {1}' -f $association, $application)

    if (-not $progID) {
        Write-Warn ('Application ''{0}'' does not declare an association for ''{1}''. Skipping.' -f $application, $association)
        $countWarning++
        continue
    }

    # Apply the association
    $output   = & $exePath $association $progID 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0) {
        Write-Success ('Set: {0} -> {1} ({2})' -f $association, $application, $progID)
        $countSuccess++
    }
    else {
        Write-ErrorLog ('Failed (exit code {0}): {1} -> {2} ({3}). Output: {4}' -f $exitCode, $association, $application, $progID, ($output -join ' '))
        $countError++
    }
}

# Summary
Write-Info ('Completed. Success: {0} | Warnings: {1} | Errors: {2}' -f $countSuccess, $countWarning, $countError)

if ($countError -gt 0) {
    exit 1
}
exit 0
