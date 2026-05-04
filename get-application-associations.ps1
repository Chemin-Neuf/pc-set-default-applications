# Copyright (C) Chemin-Neuf IT Team
# SPDX-License-Identifier: GPL-3.0-only
# Full license text: see LICENSE at the repository root
<#
.SYNOPSIS
    Discovers Windows application associations to help populate default-applications.csv.
.DESCRIPTION
    Provides four read-only discovery modes by querying the Windows registry.
    -ListApps groups registered applications by friendly display name.
    -ListAppsRaw lists all raw application names registered under RegisteredApplications.
    -ListCategories lists all distinct PerceivedType values found on this machine.
    -App shows all file and URL associations declared by a specific application.
    -Category shows all extensions of a given perceived type with their ProgIDs.
    No changes are made to the system. Use -ExportCsv with -App or -Category to
    export findings directly. Version: see $scriptVersion in the script body.

.PARAMETER ListApps
    Lists friendly application names resolved from each registration's Capabilities
    metadata. When several registered names belong to the same application, they
    are grouped together in one row.

.PARAMETER ListAppsRaw
    Lists all raw application names registered under RegisteredApplications for the
    current user and the local machine.
    These names can be used as input to -App.

.PARAMETER ListCategories
    Lists all distinct PerceivedType category names found under HKLM:\SOFTWARE\Classes.
    These names can be used as input to -Category.

.PARAMETER App
    Name of a registered application as returned by -ListAppsRaw, or a friendly
    application name as returned by -ListApps.
    Outputs objects with Type, Association, Application, RegisteredApplication,
    and ProgID properties for all file extensions and URL protocols declared by
    that application.

.PARAMETER Category
    A perceived-type category name as returned by -ListCategories (e.g. video, audio).
    Outputs objects with Association, Application, and ProgID properties for all
    extensions of that type, using the system-registered default ProgID.

.PARAMETER ExportCsv
    Path to the CSV file to create. Valid only with -App or -Category.
    The exported file uses columns Association and Application.
    Use ExportCsvMode to control whether the exported rows are active or commented.

.PARAMETER ExportCsvMode
    Controls whether exported rows are written as Active or Commented.
    Default: Commented.

.PARAMETER OverwriteCsv
    Allows overwriting an existing export file.
    Default: disabled. If the target file already exists, export stops with an error.

.PARAMETER Verbosity
    Controls console output level: None, Normal, or Detailed (default: Normal).

.PARAMETER LogVerbosity
    Controls log file output level: None, Normal, or Detailed (default: None).
    This script writes no log by default as it only reads data.

.PARAMETER Quiet
    Suppresses all console output. Takes priority over Verbosity.

.PARAMETER Version
    Displays the script name and version, then exits.

.EXAMPLE
    .\get-application-associations.ps1 -ListApps

    Lists friendly application names and the registered names behind them.

.EXAMPLE
    .\get-application-associations.ps1 -ListAppsRaw

    Lists all raw registered application names.

.EXAMPLE
    .\get-application-associations.ps1 -ListCategories

    Lists all perceived-type categories available on this machine.

.EXAMPLE
    .\get-application-associations.ps1 -App "VLC media player"

    Shows all file and URL associations declared by VLC with their ProgIDs.

.EXAMPLE
    .\get-application-associations.ps1 -App "VLC media player" -ExportCsv vlc.csv

    Exports VLC associations with all rows commented out for review.

.EXAMPLE
    .\get-application-associations.ps1 -App "VLC media player" -ExportCsv vlc.csv -ExportCsvMode Active

    Exports VLC associations with all rows active, ready to apply immediately.

.EXAMPLE
    .\get-application-associations.ps1 -App "VLC media player" -ExportCsv vlc.csv -OverwriteCsv

    Overwrites an existing vlc.csv export file.

.EXAMPLE
    .\get-application-associations.ps1 -Category video -ExportCsv video-defaults.csv

    Exports all video extensions with rows commented out for review before enabling.

.NOTES
    File:           get-application-associations.ps1
    Version:        # see $scriptVersion
    Author:         Claude Sonnet 4.6 (GitHub Copilot)
    Major Contributors: GPT-5.4 (GitHub Copilot)
    License:        GPL-3.0-only
    Prerequisites:  PowerShell 5.1+; no administrator rights required
#>

[CmdletBinding(DefaultParameterSetName = 'ListApps')]
param(
    [Parameter(ParameterSetName = 'ListApps')]
    [Alias('ListAppsFriendly')]
    [switch]$ListApps,

    [Parameter(ParameterSetName = 'ListApps')]
    [switch]$ListAppsRaw,

    [Parameter(ParameterSetName = 'ListCategories', Mandatory = $true)]
    [switch]$ListCategories,

    [Parameter(ParameterSetName = 'App', Mandatory = $true)]
    [string]$App,

    [Parameter(ParameterSetName = 'Category', Mandatory = $true)]
    [string]$Category,

    [Parameter(ParameterSetName = 'App')]
    [Parameter(ParameterSetName = 'Category')]
    [string]$ExportCsv,

    [Parameter(ParameterSetName = 'App')]
    [Parameter(ParameterSetName = 'Category')]
    [ValidateSet('Active', 'Commented')]
    [string]$ExportCsvMode = 'Commented',

    [Parameter(ParameterSetName = 'App')]
    [Parameter(ParameterSetName = 'Category')]
    [switch]$OverwriteCsv,

    [Parameter()]
    [ValidateSet('None', 'Normal', 'Detailed')]
    [string]$Verbosity = 'Normal',

    [Parameter()]
    [ValidateSet('None', 'Normal', 'Detailed')]
    [string]$LogVerbosity = 'None',

    [Parameter()]
    [switch]$Quiet,

    [Parameter()]
    [switch]$Version
)

# ============================================================
# VERSION
# ============================================================
$scriptVersion = '3.0.1'
if ($Version) {
    Write-Host ('get-application-associations.ps1  v{0}' -f $scriptVersion)
    exit 0
}

if ($Quiet) { $Verbosity = 'None' }

$exportCsvPath = $null
if ($ExportCsv) {
    $exportCsvPath = $ExportCsv
}

$script:registeredApplicationsCache = $null
$script:resolvedRegisteredApplicationsCache = @{}
$script:indirectStringCache = @{}

# ============================================================
# HELPERS
# ============================================================

<#
.SYNOPSIS
    Writes an informational message to the console, respecting Verbosity.
#>
function Write-ConsoleInfo {
    param([Parameter(Mandatory=$true)][string]$Message)
    if ($Verbosity -ne 'None') { Write-Host $Message -ForegroundColor Cyan }
}

<#
.SYNOPSIS
    Writes a detail message to the console when Verbosity is Detailed.
#>
function Write-ConsoleDetail {
    param([Parameter(Mandatory=$true)][string]$Message)
    if ($Verbosity -eq 'Detailed') {
        Write-Host ('    [detail] {0}' -f $Message) -ForegroundColor DarkGray
    }
}

<#
.SYNOPSIS
    Writes an error message to the console.
#>
function Write-ConsoleError {
    param([Parameter(Mandatory=$true)][string]$Message)
    Write-Host $Message -ForegroundColor Red
}

<#[
.SYNOPSIS
    Opens a registry subkey using the .NET registry API.

.PARAMETER Hive
    Registry hive: HKCU or HKLM.

.PARAMETER View
    Registry view: Registry64 or Registry32.

.PARAMETER SubKeyPath
    Registry path below the hive root.
#>
function Open-RegistrySubKey {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('HKCU', 'HKLM')]
        [string]$Hive,

        [Parameter(Mandatory=$true)]
        [ValidateSet('Registry64', 'Registry32')]
        [string]$View,

        [Parameter(Mandatory=$true)]
        [string]$SubKeyPath
    )

    $registryHive = if ($Hive -eq 'HKCU') {
        [Microsoft.Win32.RegistryHive]::CurrentUser
    } else {
        [Microsoft.Win32.RegistryHive]::LocalMachine
    }
    $registryView = [Microsoft.Win32.RegistryView]::$View
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($registryHive, $registryView)
    try {
        return $baseKey.OpenSubKey($SubKeyPath)
    }
    finally {
        $baseKey.Dispose()
    }
}

<#[
.SYNOPSIS
    Builds candidate capabilities-key locations for one registered application.

.PARAMETER RawPath
    Raw registry value stored under RegisteredApplications.

.PARAMETER Hive
    Source hive that declared the registration.

.PARAMETER View
    Source registry view that declared the registration.
#>
function Get-CapabilitiesKeyCandidates {
    param(
        [Parameter(Mandatory=$true)][string]$RawPath,
        [Parameter(Mandatory=$true)][string]$Hive,
        [Parameter(Mandatory=$true)][string]$View
    )

    $candidates = [System.Collections.Generic.List[PSObject]]::new()
    $seenCandidateKeys = @{}

    function Add-Candidate {
        param(
            [Parameter(Mandatory=$true)][string]$CandidateHive,
            [Parameter(Mandatory=$true)][string]$CandidateView,
            [Parameter(Mandatory=$true)][string]$CandidateSubKeyPath,
            [Parameter(Mandatory=$true)][string]$CandidatePowerShellPath
        )

        $candidateKey = '{0}|{1}|{2}' -f $CandidateHive, $CandidateView, $CandidateSubKeyPath
        if ($seenCandidateKeys.ContainsKey($candidateKey)) { return }
        $candidates.Add([PSCustomObject]@{
            Hive           = $CandidateHive
            View           = $CandidateView
            SubKeyPath     = $CandidateSubKeyPath
            PowerShellPath = $CandidatePowerShellPath
        })
        $seenCandidateKeys[$candidateKey] = $true
    }

    if ($RawPath -match '^HKEY_LOCAL_MACHINE\\(.+)$') {
        $subKeyPath = $Matches[1]
        if ($subKeyPath -match '^SOFTWARE\\WOW6432Node\\(.+)$') {
            Add-Candidate -CandidateHive 'HKLM' -CandidateView 'Registry32' -CandidateSubKeyPath ('SOFTWARE\{0}' -f $Matches[1]) -CandidatePowerShellPath ('HKLM:\SOFTWARE\WOW6432Node\{0}' -f $Matches[1])
        } else {
            Add-Candidate -CandidateHive 'HKLM' -CandidateView 'Registry64' -CandidateSubKeyPath $subKeyPath -CandidatePowerShellPath ('HKLM:\{0}' -f $subKeyPath)
        }
        return @($candidates)
    }
    if ($RawPath -match '^HKEY_CURRENT_USER\\(.+)$') {
        $subKeyPath = $Matches[1]
        if ($subKeyPath -match '^SOFTWARE\\WOW6432Node\\(.+)$') {
            Add-Candidate -CandidateHive 'HKCU' -CandidateView 'Registry32' -CandidateSubKeyPath ('SOFTWARE\{0}' -f $Matches[1]) -CandidatePowerShellPath ('HKCU:\SOFTWARE\WOW6432Node\{0}' -f $Matches[1])
        } else {
            Add-Candidate -CandidateHive 'HKCU' -CandidateView 'Registry64' -CandidateSubKeyPath $subKeyPath -CandidatePowerShellPath ('HKCU:\{0}' -f $subKeyPath)
        }
        return @($candidates)
    }
    if ($RawPath -match '^HKLM:\\(.+)$') {
        return Get-CapabilitiesKeyCandidates -RawPath ('HKEY_LOCAL_MACHINE\{0}' -f $Matches[1]) -Hive $Hive -View $View
    }
    if ($RawPath -match '^HKCU:\\(.+)$') {
        return Get-CapabilitiesKeyCandidates -RawPath ('HKEY_CURRENT_USER\{0}' -f $Matches[1]) -Hive $Hive -View $View
    }

    if ($RawPath -match '^Software\\(.+)$') {
        $relativeSoftwarePath = $Matches[1]
        if ($View -eq 'Registry32') {
            Add-Candidate -CandidateHive $Hive -CandidateView 'Registry32' -CandidateSubKeyPath ('SOFTWARE\{0}' -f $relativeSoftwarePath) -CandidatePowerShellPath ('{0}:\SOFTWARE\WOW6432Node\{1}' -f $Hive, $relativeSoftwarePath)
            Add-Candidate -CandidateHive $Hive -CandidateView 'Registry64' -CandidateSubKeyPath ('SOFTWARE\{0}' -f $relativeSoftwarePath) -CandidatePowerShellPath ('{0}:\SOFTWARE\{1}' -f $Hive, $relativeSoftwarePath)
        } else {
            Add-Candidate -CandidateHive $Hive -CandidateView 'Registry64' -CandidateSubKeyPath ('SOFTWARE\{0}' -f $relativeSoftwarePath) -CandidatePowerShellPath ('{0}:\SOFTWARE\{1}' -f $Hive, $relativeSoftwarePath)
            Add-Candidate -CandidateHive $Hive -CandidateView 'Registry32' -CandidateSubKeyPath ('SOFTWARE\{0}' -f $relativeSoftwarePath) -CandidatePowerShellPath ('{0}:\SOFTWARE\WOW6432Node\{1}' -f $Hive, $relativeSoftwarePath)
        }
        return @($candidates)
    }

    Add-Candidate -CandidateHive $Hive -CandidateView $View -CandidateSubKeyPath $RawPath -CandidatePowerShellPath ('{0}:\{1}' -f $Hive, $RawPath)
    return @($candidates)
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
    param(
        [Parameter(Mandatory=$true)][string]$RawPath,
        [AllowNull()][string]$PreferredRoot
    )

    # Normalize full HKEY_ prefixes to PowerShell drive notation
    $normalizedPath = $RawPath
    if ($normalizedPath -match '^HKEY_LOCAL_MACHINE\\(.+)$') {
        $normalizedPath = 'HKLM:\' + $Matches[1]
    } elseif ($normalizedPath -match '^HKEY_CURRENT_USER\\(.+)$') {
        $normalizedPath = 'HKCU:\' + $Matches[1]
    }

    # Already has a PS drive prefix
    if ($normalizedPath -match '^HK[A-Z]+:\\') {
        if (Test-Path $normalizedPath) { return $normalizedPath }
        # WOW6432Node fallback for fully-qualified paths
        $wow64 = $normalizedPath -replace '^(HKLM:\\SOFTWARE\\)(?!WOW6432Node)', '$1WOW6432Node\'
        if ($wow64 -ne $normalizedPath -and (Test-Path $wow64)) { return $wow64 }
        return $null
    }

    # Treat as relative — prefer the hive that registered the app, then try the other hive.
    $rootsToTry = [System.Collections.Generic.List[string]]::new()
    if ($PreferredRoot) {
        $rootsToTry.Add($PreferredRoot)
    }
    foreach ($fallbackRoot in @('HKCU:\', 'HKLM:\')) {
        if (-not $rootsToTry.Contains($fallbackRoot)) {
            $rootsToTry.Add($fallbackRoot)
        }
    }

    foreach ($root in $rootsToTry) {
        $candidatePath = $root + $normalizedPath
        if (Test-Path $candidatePath) { return $candidatePath }
    }

    # 32-bit apps on 64-bit Windows are redirected to WOW6432Node
    if ($normalizedPath -match '^Software\\(.+)$') {
        foreach ($root in $rootsToTry) {
            $wow64Path = ('{0}SOFTWARE\WOW6432Node\{1}' -f $root, $Matches[1])
            if (Test-Path $wow64Path) { return $wow64Path }
        }
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
    param([Parameter(Mandatory=$true)][string]$KeyPath)
    $key = Get-Item -Path $KeyPath -ErrorAction SilentlyContinue
    if (-not $key) { return [ordered]@{} }
    $result = [ordered]@{}
    foreach ($name in $key.GetValueNames()) {
        if ($name) { $result[$name] = $key.GetValue($name) }
    }
    return $result
}

<#
.SYNOPSIS
    Resolves an indirect Windows resource string to plain text when possible.

.PARAMETER Value
    Raw string that may contain an indirect reference such as @file,-123 or
    @{Package?ms-resource://...}.
#>
function Resolve-IndirectString {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value) -or -not $Value.StartsWith('@')) {
        return $Value
    }

    if ($script:indirectStringCache.ContainsKey($Value)) {
        return $script:indirectStringCache[$Value]
    }

    if (-not ('RegisteredApplicationNativeMethods' -as [type])) {
        Add-Type -Name 'RegisteredApplicationNativeMethods' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shlwapi.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode, SetLastError=true)]
public static extern int SHLoadIndirectString(string pszSource, System.Text.StringBuilder pszOutBuf, int cchOutBuf, System.IntPtr ppvReserved);
'@ -ErrorAction SilentlyContinue
    }

    if (-not ('RegisteredApplicationNativeMethods' -as [type])) {
        $script:indirectStringCache[$Value] = $Value
        return $Value
    }

    $buffer = New-Object System.Text.StringBuilder 1024
    $hResult = [RegisteredApplicationNativeMethods]::SHLoadIndirectString($Value, $buffer, $buffer.Capacity, [IntPtr]::Zero)
    if ($hResult -eq 0 -and $buffer.Length -gt 0) {
        $resolvedValue = $buffer.ToString()
        $script:indirectStringCache[$Value] = $resolvedValue
        return $resolvedValue
    }

    $script:indirectStringCache[$Value] = $Value
    return $Value
}

<#[
.SYNOPSIS
    Derives a readable fallback label from an unresolved AppX resource string.

.PARAMETER ResourceString
    Raw indirect resource string in @{Package?ms-resource://...} form.
#>
function Convert-AppxResourceStringToDisplayName {
    param([AllowNull()][string]$ResourceString)

    if ([string]::IsNullOrWhiteSpace($ResourceString)) { return '' }
    if ($ResourceString -notmatch '^@\{([^_\?]+)') { return '' }

    $packageName = $Matches[1]
    $leafName = ($packageName -split '\.')[-1]
    $friendlyName = $leafName -replace '([a-z0-9])([A-Z])', '$1 $2'
    $friendlyName = $friendlyName -replace '([A-Z])([A-Z][a-z])', '$1 $2'
    return $friendlyName.Trim()
}

<#
.SYNOPSIS
    Resolves the friendly display name of a registered application.

.PARAMETER RegisteredName
    Raw application name stored under RegisteredApplications.

.PARAMETER CapabilitiesPath
    Full path to the application's Capabilities registry key.
#>
function Get-RegisteredApplicationDisplayName {
    param(
        [Parameter(Mandatory=$true)][string]$RegisteredName,
        [AllowNull()][string]$ApplicationName,
        [AllowNull()][string]$CapabilitiesRawPath
    )

    if (-not $ApplicationName) { return $RegisteredName }

    $resolvedName = Resolve-IndirectString -Value $ApplicationName
    if (-not [string]::IsNullOrWhiteSpace($resolvedName) -and -not $resolvedName.StartsWith('@')) {
        return $resolvedName
    }

    $fallbackDisplayName = Convert-AppxResourceStringToDisplayName -ResourceString $ApplicationName
    if (-not [string]::IsNullOrWhiteSpace($fallbackDisplayName)) {
        return $fallbackDisplayName
    }

    if ($RegisteredName -match '^([^.]+)\.Application\.\d+$') {
        return $Matches[1]
    }

    if ($RegisteredName -match '^(.+?)-[A-F0-9]{8,}$') {
        return $Matches[1]
    }

    if ($RegisteredName -like 'AppX*' -and $CapabilitiesRawPath -match '\\([^\\]+)\\Capabilities$') {
        $leafName = ($Matches[1] -split '\.')[-1]
        $leafName = $leafName -replace '([a-z0-9])([A-Z])', '$1 $2'
        $leafName = $leafName -replace '([A-Z])([A-Z][a-z])', '$1 $2'
        if (-not [string]::IsNullOrWhiteSpace($leafName) -and $leafName -ne 'App') {
            return $leafName.Trim()
        }
    }

    return $RegisteredName
}

<#
.SYNOPSIS
    Returns all raw RegisteredApplications entries visible to this user.

.DESCRIPTION
    Combines per-user and machine-wide registrations. User-scoped entries are
    preferred when the same application name exists in multiple hives. Friendly
    names and capabilities paths are resolved lazily only when needed.
#>
function Get-RegisteredApplications {
    if ($script:registeredApplicationsCache) {
        return $script:registeredApplicationsCache
    }

    $registeredApplications = [ordered]@{}
    $registeredApplicationPaths = @(
        [PSCustomObject]@{ Hive = 'HKCU'; View = 'Registry64'; SubKeyPath = 'SOFTWARE\RegisteredApplications' },
        [PSCustomObject]@{ Hive = 'HKCU'; View = 'Registry32'; SubKeyPath = 'SOFTWARE\RegisteredApplications' },
        [PSCustomObject]@{ Hive = 'HKLM'; View = 'Registry64'; SubKeyPath = 'SOFTWARE\RegisteredApplications' },
        [PSCustomObject]@{ Hive = 'HKLM'; View = 'Registry32'; SubKeyPath = 'SOFTWARE\RegisteredApplications' }
    )

    foreach ($registeredApplicationLocation in $registeredApplicationPaths) {
        $appsKey = Open-RegistrySubKey -Hive $registeredApplicationLocation.Hive -View $registeredApplicationLocation.View -SubKeyPath $registeredApplicationLocation.SubKeyPath
        if (-not $appsKey) { continue }

        try {
            foreach ($appName in ($appsKey.GetValueNames() | Where-Object { $_ } | Sort-Object)) {
                if ($registeredApplications.Contains($appName)) { continue }
                $registeredApplications[$appName] = [PSCustomObject]@{
                    RegisteredName      = $appName
                    Hive                = $registeredApplicationLocation.Hive
                    View                = $registeredApplicationLocation.View
                    CapabilitiesRawPath = [string]$appsKey.GetValue($appName)
                }
            }
        }
        finally {
            $appsKey.Dispose()
        }
    }

    $script:registeredApplicationsCache = $registeredApplications
    return $script:registeredApplicationsCache
}

<#
.SYNOPSIS
    Resolves cached display metadata for one registered application entry.

.PARAMETER RegisteredApplication
    Raw registered application entry returned by Get-RegisteredApplications.
#>
function Resolve-RegisteredApplication {
    param([Parameter(Mandatory=$true)]$RegisteredApplication)

    if ($script:resolvedRegisteredApplicationsCache.ContainsKey($RegisteredApplication.RegisteredName)) {
        return $script:resolvedRegisteredApplicationsCache[$RegisteredApplication.RegisteredName]
    }

    $capabilitiesPath = $null
    $applicationName = $null
    if ($RegisteredApplication.CapabilitiesRawPath) {
        foreach ($candidate in (Get-CapabilitiesKeyCandidates -RawPath $RegisteredApplication.CapabilitiesRawPath -Hive $RegisteredApplication.Hive -View $RegisteredApplication.View)) {
            $capabilitiesKey = Open-RegistrySubKey -Hive $candidate.Hive -View $candidate.View -SubKeyPath $candidate.SubKeyPath
            if (-not $capabilitiesKey) { continue }

            try {
                $capabilitiesPath = $candidate.PowerShellPath
                $applicationName = [string]$capabilitiesKey.GetValue('ApplicationName')
                break
            }
            finally {
                $capabilitiesKey.Dispose()
            }
        }
    }

    $resolvedApplication = [PSCustomObject]@{
        RegisteredName      = $RegisteredApplication.RegisteredName
        DisplayName         = Get-RegisteredApplicationDisplayName -RegisteredName $RegisteredApplication.RegisteredName -ApplicationName $applicationName -CapabilitiesRawPath $RegisteredApplication.CapabilitiesRawPath
        Hive                = $RegisteredApplication.Hive
        View                = $RegisteredApplication.View
        CapabilitiesRawPath = $RegisteredApplication.CapabilitiesRawPath
        CapabilitiesPath    = $capabilitiesPath
    }

    $script:resolvedRegisteredApplicationsCache[$RegisteredApplication.RegisteredName] = $resolvedApplication
    return $resolvedApplication
}

<#
.SYNOPSIS
    Resolves one or more registered application entries from either a raw or friendly name.

.PARAMETER Application
    Raw application name or friendly display name.

.PARAMETER RegisteredApplications
    Hashtable returned by Get-RegisteredApplications.
#>
function Resolve-RegisteredApplicationEntries {
    param(
        [Parameter(Mandatory=$true)][string]$Application,
        [Parameter(Mandatory=$true)][hashtable]$RegisteredApplications
    )

    if ($RegisteredApplications.ContainsKey($Application)) {
        return @(Resolve-RegisteredApplication -RegisteredApplication $RegisteredApplications[$Application])
    }

    $matches = foreach ($registeredApplication in $RegisteredApplications.Values) {
        $resolvedApplication = Resolve-RegisteredApplication -RegisteredApplication $registeredApplication
        if ($resolvedApplication.DisplayName -eq $Application) {
            $resolvedApplication
        }
    }

    return @($matches | Sort-Object RegisteredName)
}

<#
.SYNOPSIS
    Groups registered applications by their friendly display name.

.PARAMETER RegisteredApplications
    Hashtable returned by Get-RegisteredApplications.
#>
function Get-FriendlyRegisteredApplications {
    param([Parameter(Mandatory=$true)][hashtable]$RegisteredApplications)

    $resolvedApplications = foreach ($registeredApplication in $RegisteredApplications.Values) {
        Resolve-RegisteredApplication -RegisteredApplication $registeredApplication
    }

    $results = foreach ($group in ($resolvedApplications | Group-Object DisplayName | Sort-Object Name)) {
        [PSCustomObject]@{
            Application            = $group.Name
            RegisteredApplications = ($group.Group | Sort-Object RegisteredName | ForEach-Object { $_.RegisteredName }) -join '; '
        }
    }

    return @($results)
}

<#
.SYNOPSIS
    Finds the registered application name that declares a specific association/ProgID pair.

.PARAMETER Association
    File extension or protocol.

.PARAMETER ProgID
    Declared ProgID for the association.
#>
function Resolve-ApplicationNameForAssociation {
    param(
        [Parameter(Mandatory=$true)][string]$Association,
        [Parameter(Mandatory=$true)][string]$ProgID
    )

    $registeredApplications = Get-RegisteredApplications
    if ($registeredApplications.Count -eq 0) { return '' }

    foreach ($appName in ($registeredApplications.Keys | Sort-Object)) {
        $registeredApplication = Resolve-RegisteredApplication -RegisteredApplication $registeredApplications[$appName]
        $capPath = $registeredApplication.CapabilitiesPath
        if (-not $capPath) { continue }

        $associationPath = if ($Association.StartsWith('.')) {
            Join-Path $capPath 'FileAssociations'
        } else {
            Join-Path $capPath 'URLAssociations'
        }

        $values = Get-RegistryValues -KeyPath $associationPath
        if ($values.Contains($Association) -and $values[$Association] -eq $ProgID) {
            return $registeredApplication.DisplayName
        }
    }

    return ''
}

<#
.SYNOPSIS
    Escapes a value for CSV output when needed.

.PARAMETER Value
    Raw string value to escape.
#>
function Format-CsvValue {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { return '' }
    if ($Value -match '[",\r\n]') {
        return '"{0}"' -f ($Value -replace '"', '""')
    }
    return $Value
}

<#
.SYNOPSIS
    Writes Association and ProgID data to a CSV file compatible with set-default-applications.ps1.

.PARAMETER Results
    Collection of objects with Association and Application properties.

.PARAMETER Path
    Destination file path.

.PARAMETER Active
    When set, rows are written without a leading # (immediately active).
    Default is to prefix each row with # for review.

.PARAMETER Overwrite
    Allows overwriting the destination file when it already exists.
#>
function Write-AssociationCsv {
    param(
        [Parameter(Mandatory=$true)]$Results,
        [Parameter(Mandatory=$true)][string]$Path,
        [switch]$Active,
        [switch]$Overwrite
    )
    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $parentDir = [System.IO.Path]::GetDirectoryName($resolvedPath)
    if ($parentDir -and -not (Test-Path $parentDir)) {
        Write-ConsoleError ('Output directory does not exist: {0}' -f $parentDir)
        return $false
    }
    if ((Test-Path $resolvedPath) -and -not $Overwrite) {
        Write-ConsoleError ('Output file already exists: {0}. Use -OverwriteCsv to replace it.' -f $resolvedPath)
        return $false
    }
    $prefix = if ($Active) { '' } else { '#' }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add(('# Generated by get-application-associations.ps1 on {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
    if (-not $Active) {
        $lines.Add('# Remove the leading # from each line you want to activate, then run set-default-applications.ps1.')
    }
    $lines.Add('Association,Application')
    foreach ($item in ($Results | Sort-Object Association)) {
        $lines.Add(('{0}{1},{2}' -f $prefix, (Format-CsvValue -Value $item.Association), (Format-CsvValue -Value $item.Application)))
    }
    [System.IO.File]::WriteAllLines($resolvedPath, $lines)
    Write-ConsoleInfo ('CSV written: {0}' -f $resolvedPath)
    return $true
}

# ============================================================
# MODE: LIST APPS
# ============================================================
if ($PSCmdlet.ParameterSetName -eq 'ListApps') {
    $registeredApplications = Get-RegisteredApplications
    if (-not $ListAppsRaw) {
        $friendlyApplications = Get-FriendlyRegisteredApplications -RegisteredApplications $registeredApplications
        if (-not $friendlyApplications) {
            Write-Warning 'No registered applications found.'
            exit 0
        }
        Write-ConsoleInfo ('{0} friendly application name(s) found across {1} registered entry/entries:' -f $friendlyApplications.Count, $registeredApplications.Count)
        $friendlyApplications | Write-Output
        exit 0
    }

    $names = $registeredApplications.Keys | Sort-Object
    if (-not $names) {
        Write-Warning 'No registered applications found.'
        exit 0
    }
    Write-ConsoleInfo ('{0} registered application(s):' -f @($names).Count)
    $names | Write-Output
    exit 0
}

# ============================================================
# MODE: LIST CATEGORIES
# ============================================================
if ($PSCmdlet.ParameterSetName -eq 'ListCategories') {
    $categories = Get-ChildItem -Path 'HKLM:\SOFTWARE\Classes' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^\.' } |
        ForEach-Object { $_.GetValue('PerceivedType') } |
        Where-Object { $_ } |
        Sort-Object -Unique

    if (-not $categories) {
        Write-Warning 'No perceived-type categories found.'
        exit 0
    }
    Write-ConsoleInfo ('{0} category/categories found:' -f @($categories).Count)
    $categories | Write-Output
    exit 0
}

# ============================================================
# MODE: APP
# ============================================================
if ($PSCmdlet.ParameterSetName -eq 'App') {
    $registeredApplications = Get-RegisteredApplications
    if ($registeredApplications.Count -eq 0) {
        Write-Error 'No registered applications found.'
        exit 1
    }

    $selectedApplications = Resolve-RegisteredApplicationEntries -Application $App -RegisteredApplications $registeredApplications
    if ($selectedApplications.Count -eq 0) {
        Write-Error ('Application not found: {0}' -f $App)
        Write-ConsoleInfo 'Run with -ListApps or -ListAppsRaw to see available application names.'
        exit 1
    }

    $displayName = $selectedApplications[0].DisplayName

    $results = [System.Collections.Generic.List[PSObject]]::new()
    $seenAssociations = @{}

    foreach ($selectedApplication in $selectedApplications) {
        if (-not $selectedApplication.CapabilitiesPath) {
            Write-ConsoleDetail ('Skipping ''{0}'': capabilities registry key not found. Raw path from registry: {1}' -f $selectedApplication.RegisteredName, $selectedApplication.CapabilitiesRawPath)
            continue
        }

        Write-ConsoleDetail ('Capabilities subkey for ''{0}'': {1}' -f $selectedApplication.RegisteredName, $selectedApplication.CapabilitiesRawPath)

        # File associations
        $fileAssocPath = Join-Path $selectedApplication.CapabilitiesPath 'FileAssociations'
        if (Test-Path $fileAssocPath) {
            $values = Get-RegistryValues -KeyPath $fileAssocPath
            foreach ($ext in ($values.Keys | Sort-Object)) {
                $associationKey = 'Extension|{0}' -f $ext
                if ($seenAssociations.ContainsKey($associationKey)) { continue }

                $results.Add([PSCustomObject]@{
                    Type                  = 'Extension'
                    Association           = $ext
                    Application           = $displayName
                    RegisteredApplication = $selectedApplication.RegisteredName
                    ProgID                = $values[$ext]
                })
                $seenAssociations[$associationKey] = $true
            }
            Write-ConsoleDetail ('{0} file association(s) found for ''{1}''.' -f $values.Count, $selectedApplication.RegisteredName)
        } else {
            Write-ConsoleDetail ('No FileAssociations subkey found for ''{0}''.' -f $selectedApplication.RegisteredName)
        }

        # URL / protocol associations
        $urlAssocPath = Join-Path $selectedApplication.CapabilitiesPath 'URLAssociations'
        if (Test-Path $urlAssocPath) {
            $values = Get-RegistryValues -KeyPath $urlAssocPath
            foreach ($proto in ($values.Keys | Sort-Object)) {
                $associationKey = 'Protocol|{0}' -f $proto
                if ($seenAssociations.ContainsKey($associationKey)) { continue }

                $results.Add([PSCustomObject]@{
                    Type                  = 'Protocol'
                    Association           = $proto
                    Application           = $displayName
                    RegisteredApplication = $selectedApplication.RegisteredName
                    ProgID                = $values[$proto]
                })
                $seenAssociations[$associationKey] = $true
            }
            Write-ConsoleDetail ('{0} URL association(s) found for ''{1}''.' -f $values.Count, $selectedApplication.RegisteredName)
        } else {
            Write-ConsoleDetail ('No URLAssociations subkey found for ''{0}''.' -f $selectedApplication.RegisteredName)
        }
    }

    if ($results.Count -eq 0) {
        Write-Warning ('No associations found for: {0}' -f $App)
        exit 0
    }

    Write-ConsoleInfo ('{0} association(s) found for: {1}' -f $results.Count, $displayName)
    if ($Verbosity -ne 'None') {
        $results | Sort-Object Type, Association | Format-Table -AutoSize | Out-String | Write-Host
    }
    $results | Sort-Object Type, Association | Write-Output
    if ($exportCsvPath) {
        $exportSucceeded = Write-AssociationCsv -Results $results -Path $exportCsvPath -Active:($exportCsvMode -eq 'Active') -Overwrite:$OverwriteCsv
        if (-not $exportSucceeded) { exit 1 }
    }
    exit 0
}

# ============================================================
# MODE: CATEGORY
# ============================================================
if ($PSCmdlet.ParameterSetName -eq 'Category') {
    $results = [System.Collections.Generic.List[PSObject]]::new()

    Get-ChildItem -Path 'HKLM:\SOFTWARE\Classes' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^\.' } |
        ForEach-Object {
            $extKey        = $_
            $perceivedType = $extKey.GetValue('PerceivedType')
            if ($perceivedType -eq $Category) {
                $progID = $extKey.GetValue('')   # default value = system ProgID
                $resolvedProgID = ''
                $applicationName = ''
                if ($progID) {
                    $resolvedProgID = $progID
                    $applicationName = Resolve-ApplicationNameForAssociation -Association $extKey.PSChildName -ProgID $resolvedProgID
                }

                $results.Add([PSCustomObject]@{
                    Association = $extKey.PSChildName
                    Application = $applicationName
                    ProgID      = $resolvedProgID
                })
            }
        }

    if ($results.Count -eq 0) {
        Write-Warning ('No extensions found for category: {0}' -f $Category)
        Write-ConsoleInfo 'Run with -ListCategories to see available categories.'
        exit 0
    }

    Write-ConsoleInfo ('{0} extension(s) found for category: {1}' -f $results.Count, $Category)
    if ($Verbosity -ne 'None') {
        $results | Sort-Object Association | Format-Table -AutoSize | Out-String | Write-Host
    }
    $results | Sort-Object Association | Write-Output
    if ($exportCsvPath) {
        $exportSucceeded = Write-AssociationCsv -Results $results -Path $exportCsvPath -Active:($exportCsvMode -eq 'Active') -Overwrite:$OverwriteCsv
        if (-not $exportSucceeded) { exit 1 }
    }
    exit 0
}
