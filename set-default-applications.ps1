# Copyright (C) Chemin-Neuf IT Team
# SPDX-License-Identifier: GPL-3.0-only
# Full license text: see LICENSE at the repository root

<#
.SYNOPSIS
    Sets Windows 11 default applications for file extensions and protocols.

.DESCRIPTION
    Reads a CSV configuration file listing file-extension-to-application and
    protocol-to-application associations, resolves the corresponding ProgID in
    the registry, and applies the defaults using SetUserFTA. The Application
    column may use either the raw RegisteredApplications name or the friendly
    display name exposed by the discovery script. Configuration can come either
    from one CSV file or from a TXT manifest listing multiple CSV files in the
    exact order they should be processed.
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
    the manifest file's directory. For example, relative.csv resolves next to
    the manifest, ..\parent.csv resolves from the manifest's parent, and
    absolute paths are used unchanged. The Application column may contain either
    the raw registered application name or a friendly application name.
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

.PARAMETER SetUserFTAVersion
    Checks whether SetUserFTA.exe is present at the configured cache path,
    reports its version if found, then exits. Does not modify any association.

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

.EXAMPLE
    .\set-default-applications.ps1 -SetUserFTAVersion

    Reports whether SetUserFTA.exe is present at the cache path and its version.

.NOTES
    File:           set-default-applications.ps1
    Version:        2.8.0
    Author:         Claude Sonnet 4.6 (GitHub Copilot)
    Major Contributors: GPT-5.4 (GitHub Copilot)
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
    [switch]$SetUserFTAVersion,

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
$scriptVersion = '2.8.0'
if ($Version) {
    Write-Host ('set-default-applications.ps1  v{0}' -f $scriptVersion)
    exit 0
}

# ============================================================
# CONFIGURATION
# ============================================================
$setUserFTACachePath        = 'C:\Support\SetUserFTA.exe'
$setUserFTADownloadUrl      = 'https://setuserfta.com/SetUserFTA.zip'
$setUserFTANetworkPath      = '\\your-server\your-share\SetUserFTA.exe'
$setUserFTAKnownFreeVersion = '1.8.4'   # latest personal/free edition — update this when a new version is released
# UCPD-protected associations — these require UCPD to be disabled before SetUserFTA can apply them.
$ucpdProtectedExtensions = @('.htm', '.html', '.pdf', '.svg', '.xhtml', '.shtml', '.webp')
$ucpdProtectedProtocols  = @('http', 'https')

if (-not $ConfigPath) {
    if ($ConfigType -eq 'TXT') {
        $ConfigPath = Join-Path $PSScriptRoot 'default-applications.txt'
    }
    else {
        $ConfigPath = Join-Path $PSScriptRoot 'default-applications.csv'
    }
}

if ($SetUserFTAVersion) {
    if (Test-Path $setUserFTACachePath) {
        $cachedVersion = (Get-Item $setUserFTACachePath).VersionInfo.FileVersion
        Write-Host ('SetUserFTA.exe found at:          {0}' -f $setUserFTACachePath)
        Write-Host ('Version installed:                {0}' -f $cachedVersion)
        Write-Host ('Latest known free version:        {0}' -f $setUserFTAKnownFreeVersion)

        try {
            $installedVer = [System.Version]$cachedVersion
            $knownVer     = [System.Version]$setUserFTAKnownFreeVersion
            if ($installedVer -lt $knownVer) {
                Write-Warning ('Installed version ({0}) is older than the latest known free version ({1}). Consider updating SetUserFTA.exe.' -f $cachedVersion, $setUserFTAKnownFreeVersion)
            }
            elseif ($installedVer -gt $knownVer) {
                Write-Host ('Installed version ({0}) is newer than the free version tracked by this script ({1}). Update $setUserFTAKnownFreeVersion in the CONFIGURATION section.' -f $cachedVersion, $setUserFTAKnownFreeVersion) -ForegroundColor Cyan
            }
            else {
                Write-Host 'Installed version matches the latest known free version.' -ForegroundColor Green
            }
        }
        catch {
            Write-Warning ('Could not parse version string for comparison: {0}' -f $cachedVersion)
        }
    }
    else {
        Write-Host ('SetUserFTA.exe not found at: {0}' -f $setUserFTACachePath)
    }
    exit 0
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
$sharedUtilsPath = Join-Path $PSScriptRoot 'SharedUtils.psd1'
if (-not (Test-Path $sharedUtilsPath)) {
    Write-Error ('SharedUtils.psd1 not found at: {0}' -f $sharedUtilsPath)
    exit 1
}
Import-Module $sharedUtilsPath -Force

$appRegistryPath = Join-Path $PSScriptRoot 'ApplicationRegistry.psm1'
if (-not (Test-Path $appRegistryPath)) {
    Write-Error ('ApplicationRegistry.psm1 not found at: {0}' -f $appRegistryPath)
    exit 1
}
Import-Module $appRegistryPath -Force

$ucpdUtilsPath = Join-Path $PSScriptRoot 'UcpdUtils.psm1'
if (-not (Test-Path $ucpdUtilsPath)) {
    Write-Error ('UcpdUtils.psm1 not found at: {0}' -f $ucpdUtilsPath)
    exit 1
}
Import-Module $ucpdUtilsPath -Force

# ============================================================
# LOGGING
# ============================================================
Initialize-Log -ScriptName 'set-default-applications' -Version $scriptVersion
Initialize-ConsoleEncoding

# ============================================================
# FUNCTIONS
# ============================================================

<#
.SYNOPSIS
    Returns the file version of an executable as a System.Version, or $null if it
    cannot be read or parsed.

.PARAMETER Path
    Full path to the executable.
#>
function Get-ExeFileVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path
    )
    try {
        $raw = (Get-Item $Path -ErrorAction Stop).VersionInfo.FileVersion
        return [System.Version]$raw
    }
    catch { return $null }
}

<#
.SYNOPSIS
    Locates or obtains SetUserFTA.exe at or above the required minimum version.

.PARAMETER CachePath
    Target path where SetUserFTA.exe should be stored and reused.

.PARAMETER DownloadUrl
    URL to a ZIP archive containing SetUserFTA.exe.

.PARAMETER NetworkPath
    UNC path to a SetUserFTA.exe file used as a fallback if download fails.

.PARAMETER MinimumVersion
    Minimum acceptable version string (e.g. '1.8.4'). If the cached copy is
    below this version, a fresh copy is obtained. The script proceeds with
    whatever version is ultimately found, with a warning when it is outdated.

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
        [string]$NetworkPath,

        [Parameter(Mandatory=$true)]
        [string]$MinimumVersion
    )

    $minVer          = [System.Version]$MinimumVersion
    $outdatedMessage = ('Proceeding anyway — associations for UCPD-protected extensions (e.g. .pdf) may not be applied correctly.' )

    # 1. Already cached — accept only if version meets the minimum
    if (Test-Path $CachePath) {
        $cachedVer = Get-ExeFileVersion $CachePath
        if ($null -ne $cachedVer -and $cachedVer -ge $minVer) {
            Write-Detail ('SetUserFTA found at cache path (v{0}): {1}' -f $cachedVer, $CachePath)
            return $CachePath
        }
        Write-Warn ('Cached SetUserFTA (v{0}) is older than the minimum required version (v{1}). Attempting to obtain a newer copy.' -f $cachedVer, $MinimumVersion)
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
    $zipPath        = Join-Path $env:TEMP 'SetUserFTA.zip'
    $downloadedPath = $null
    try {
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        Expand-Archive -Path $zipPath -DestinationPath $cacheDir -Force -ErrorAction Stop
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

        $resolvedDownload = $null
        if (Test-Path $effectiveCachePath) {
            $resolvedDownload = $effectiveCachePath
        }
        else {
            $found = Get-ChildItem -Path $cacheDir -Filter 'SetUserFTA.exe' -Recurse -ErrorAction SilentlyContinue |
                     Select-Object -First 1
            if ($found) { $resolvedDownload = $found.FullName }
        }

        if ($resolvedDownload) {
            $downloadedVer = Get-ExeFileVersion $resolvedDownload
            if ($null -ne $downloadedVer -and $downloadedVer -ge $minVer) {
                Write-Success ('SetUserFTA downloaded (v{0}): {1}' -f $downloadedVer, $resolvedDownload)
                return $resolvedDownload
            }
            Write-Warn ('Downloaded SetUserFTA (v{0}) is older than the minimum required version (v{1}). Falling back to network share.' -f $downloadedVer, $MinimumVersion)
            $downloadedPath = $resolvedDownload
        }
        else {
            Write-Warn 'Download succeeded but SetUserFTA.exe was not found after extraction.'
        }
    }
    catch {
        Write-Warn ('Download failed: {0}' -f $_.Exception.Message)
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    }

    # 3. Try copying from network path
    Write-Info ('Attempting to copy SetUserFTA from network: {0}' -f $NetworkPath)
    try {
        Copy-Item -Path $NetworkPath -Destination $effectiveCachePath -Force -ErrorAction Stop
        $networkVer = Get-ExeFileVersion $effectiveCachePath
        if ($null -ne $networkVer -and $networkVer -lt $minVer) {
            Write-Warn ('Network SetUserFTA (v{0}) is older than the minimum required version (v{1}). {2}' -f $networkVer, $MinimumVersion, $outdatedMessage)
        }
        else {
            Write-Success ('SetUserFTA copied from network (v{0}): {1}' -f $networkVer, $effectiveCachePath)
        }
        return $effectiveCachePath
    }
    catch {
        Write-Warn ('Network copy failed: {0}' -f $_.Exception.Message)
    }

    # 4. Last resort: use the downloaded copy even though it is outdated
    if ($null -ne $downloadedPath -and (Test-Path $downloadedPath)) {
        $downloadedVer = Get-ExeFileVersion $downloadedPath
        Write-Warn ('Using downloaded SetUserFTA (v{0}), which is older than the minimum required version (v{1}). {2}' -f $downloadedVer, $MinimumVersion, $outdatedMessage)
        return $downloadedPath
    }

    # 5. Very last resort: stale cache
    if (Test-Path $CachePath) {
        $cachedVer = Get-ExeFileVersion $CachePath
        Write-Warn ('Using stale cached SetUserFTA (v{0}), which is older than the minimum required version (v{1}). {2}' -f $cachedVer, $MinimumVersion, $outdatedMessage)
        return $CachePath
    }

    return $null
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

    $rawApplications = Get-RegisteredApplications
    if ($rawApplications.Count -eq 0) {
        Write-ErrorLog 'RegisteredApplications not found in HKCU or HKLM.'
        return @{}
    }

    $applications = @{}
    foreach ($appName in ($rawApplications.Keys | Sort-Object)) {
        $registeredApplication = Resolve-RegisteredApplication -RegisteredApplication $rawApplications[$appName]
        $capabilitiesPath = $registeredApplication.CapabilitiesPath
        if (-not $capabilitiesPath) {
            Write-Detail ('Skipping application ''{0}'': capabilities path not found.' -f $appName)
            continue
        }

        $applications[$appName] = @{
            DisplayName      = $registeredApplication.DisplayName
            RegisteredName   = $registeredApplication.RegisteredName
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
    Registered application name exactly as listed under RegisteredApplications,
    or a friendly application name resolved from Capabilities\ApplicationName.

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

    if ($ApplicationMap.ContainsKey($Application)) {
        $candidateApplications = @($ApplicationMap[$Application])
    }
    else {
        $candidateApplications = @(
            $ApplicationMap.Values |
                Where-Object { $_.DisplayName -eq $Application -or (Remove-TrailingVersion -Name $_.DisplayName) -eq $Application } |
                Sort-Object RegisteredName
        )
    }

    foreach ($candidateApplication in $candidateApplications) {
        $associationMap = if ($Association.StartsWith('.')) {
            $candidateApplication.FileAssociations
        } else {
            $candidateApplication.URLAssociations
        }

        if ($associationMap.Contains($Association)) {
            return $associationMap[$Association]
        }
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
                                   -NetworkPath $setUserFTANetworkPath `
                                   -MinimumVersion $setUserFTAKnownFreeVersion
}

if (-not $exePath -or -not (Test-Path $exePath)) {
    Write-ErrorLog 'SetUserFTA.exe could not be found or obtained. Aborting.'
    exit 1
}
$setUserFTAFileVersion = (Get-Item $exePath).VersionInfo.FileVersion
Write-Info ('Using SetUserFTA: {0} (v{1})' -f $exePath, $setUserFTAFileVersion)

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

# ---- UCPD pre-check ----
# Determine whether any requested association is UCPD-protected.
$requestedUcpdAssociations = $associations | Where-Object {
    $a = $_.Association.Trim()
    ($ucpdProtectedExtensions -contains $a) -or ($ucpdProtectedProtocols -contains $a)
}

$ucpdStillActive   = $false
$ucpdReasonMessage = ''
$ucpdNextAction    = ''

if ($requestedUcpdAssociations) {
    Write-Info ('UCPD-protected associations requested ({0}). Checking UCPD status...' -f (($requestedUcpdAssociations | ForEach-Object { $_.Association.Trim() }) -join ', '))
    $ucpdStatus = Get-UcpdStatus

    if ($ucpdStatus.IsActive) {
        Write-Warn 'UCPD is active. Attempting to disable it so protected associations can be applied...'

        if (-not $ucpdStatus.IsAdmin) {
            $ucpdStillActive   = $true
            $ucpdReasonMessage = 'UCPD is active and this session does not have administrator rights. Protected associations cannot be applied.'
            $ucpdNextAction    = 'Re-run this script from an elevated PowerShell prompt (Run as administrator).'
            Write-Warn $ucpdReasonMessage
        }
        else {
            $disableResult = Set-UcpdState -State Disabled

            if (-not $disableResult.Success) {
                $ucpdStillActive   = $true
                $ucpdReasonMessage = ('Failed to disable UCPD: {0}' -f $disableResult.Message)
                $ucpdNextAction    = 'Check the log for details and retry from an elevated prompt.'
                Write-Warn $ucpdReasonMessage
            }
            elseif ($disableResult.RequiresReboot) {
                $ucpdStillActive   = $true
                $ucpdReasonMessage = 'UCPD was configured as Disabled but the driver is still running and requires a reboot to stop.'
                $ucpdNextAction    = 'Reboot this computer, then re-run the script.'
                Write-Warn ('UCPD disabled in configuration but driver is still running: {0}' -f $disableResult.Message)
            }
            else {
                Write-Success 'UCPD disabled and driver stopped. Protected associations will now be applied.'
            }
        }
    }
    else {
        Write-Info 'UCPD is not active. Protected associations will be applied normally.'
    }
}

# ---- Association loop ----
$ucpdSkippedAssociations = [System.Collections.Generic.List[string]]::new()

foreach ($row in $associations) {
    $association = $row.Association.Trim()
    $application = $row.Application.Trim()

    if (-not $association) {
        Write-Warn ('Skipping row from ''{0}'' because Association is empty.' -f $row.SourcePath)
        $countWarning++
        continue
    }

    if (-not $application) {
        Write-Warn ('Skipping ''{0}'' from ''{1}'' because no application is specified.' -f $association, $row.SourcePath)
        $countWarning++
        continue
    }

    # Skip UCPD-protected associations when UCPD is still active
    if ($ucpdStillActive) {
        $isProtected = ($ucpdProtectedExtensions -contains $association) -or ($ucpdProtectedProtocols -contains $association)
        if ($isProtected) {
            Write-Warn ('Skipping UCPD-protected association ''{0}'' because UCPD is still active.' -f $association)
            $ucpdSkippedAssociations.Add($association)
            $countWarning++
            continue
        }
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

if ($ucpdStillActive -and $ucpdSkippedAssociations.Count -gt 0) {
    Write-ErrorLog ('The following UCPD-protected associations were skipped because UCPD is still active: {0}' -f ($ucpdSkippedAssociations -join ', '))
    Write-ErrorLog ('Reason: {0}' -f $ucpdReasonMessage)
    Write-ErrorLog ('Next action: {0}' -f $ucpdNextAction)
    $countError++
}

if ($countError -gt 0) {
    exit 1
}
exit 0