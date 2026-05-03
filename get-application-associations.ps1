# Copyright (C) Chemin-Neuf IT Team
# SPDX-License-Identifier: GPL-3.0-only
# Full license text: see LICENSE at the repository root
<#
.SYNOPSIS
    Discovers Windows application associations to help populate default-applications.csv.

.DESCRIPTION
    Provides four read-only discovery modes by querying the Windows registry.
    -ListApps lists all applications registered under RegisteredApplications.
    -ListCategories lists all distinct PerceivedType values found on this machine.
    -App shows all file and URL associations declared by a specific application.
    -Category shows all extensions of a given perceived type with their ProgIDs.
    No changes are made to the system. Output from -App and -Category can be
    piped to Export-Csv for direct use with default-applications.csv.

.PARAMETER ListApps
    Lists all application names registered under HKLM:\SOFTWARE\RegisteredApplications.
    These names can be used as input to -App.

.PARAMETER ListCategories
    Lists all distinct PerceivedType category names found under HKLM:\SOFTWARE\Classes.
    These names can be used as input to -Category.

.PARAMETER App
    Name of a registered application exactly as returned by -ListApps.
    Outputs objects with Type, Association, and ProgID properties for all file
    extensions and URL protocols declared by that application.

.PARAMETER Category
    A perceived-type category name as returned by -ListCategories (e.g. video, audio).
    Outputs objects with Association and ProgID properties for all extensions of
    that type, using the system-registered default ProgID.

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

    Lists all registered application names.

.EXAMPLE
    .\get-application-associations.ps1 -ListCategories

    Lists all perceived-type categories available on this machine.

.EXAMPLE
    .\get-application-associations.ps1 -App "VLC media player"

    Shows all file and URL associations declared by VLC with their ProgIDs.

.EXAMPLE
    .\get-application-associations.ps1 -Category video | Export-Csv -Path video.csv -NoTypeInformation

    Exports all video extensions and their system ProgIDs to a CSV file.

.NOTES
    File:           get-application-associations.ps1
    Version:        1.0.0
    Author:         Claude Sonnet 4.6 (GitHub Copilot)
    License:        GPL-3.0-only
    Prerequisites:  PowerShell 5.1+; no administrator rights required
#>

[CmdletBinding(DefaultParameterSetName = 'ListApps')]
param(
    [Parameter(ParameterSetName = 'ListApps')]
    [switch]$ListApps,

    [Parameter(ParameterSetName = 'ListCategories', Mandatory = $true)]
    [switch]$ListCategories,

    [Parameter(ParameterSetName = 'App', Mandatory = $true)]
    [string]$App,

    [Parameter(ParameterSetName = 'Category', Mandatory = $true)]
    [string]$Category,

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
$scriptVersion = '1.0.0'
if ($Version) {
    Write-Host ('get-application-associations.ps1  v{0}' -f $scriptVersion)
    exit 0
}

if ($Quiet) { $Verbosity = 'None' }

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
    Resolves the full PowerShell registry path to an application's Capabilities subkey.
    Handles both relative paths (Software\...) and absolute paths (HKEY_LOCAL_MACHINE\...).
    Checks HKLM first, then HKCU.

.PARAMETER RawPath
    The path value stored in RegisteredApplications. May be relative or include a full
    HKEY_LOCAL_MACHINE / HKEY_CURRENT_USER prefix.
#>
function Resolve-CapabilitiesPath {
    param([Parameter(Mandatory=$true)][string]$RawPath)

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

    # Treat as relative — try HKLM then HKCU, with WOW6432Node fallback for 32-bit apps
    $hklmPath = 'HKLM:\' + $normalizedPath
    if (Test-Path $hklmPath) { return $hklmPath }
    $hkcuPath = 'HKCU:\' + $normalizedPath
    if (Test-Path $hkcuPath) { return $hkcuPath }

    # 32-bit apps on 64-bit Windows are redirected to WOW6432Node
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
    param([Parameter(Mandatory=$true)][string]$KeyPath)
    $key = Get-Item -Path $KeyPath -ErrorAction SilentlyContinue
    if (-not $key) { return [ordered]@{} }
    $result = [ordered]@{}
    foreach ($name in $key.GetValueNames()) {
        if ($name) { $result[$name] = $key.GetValue($name) }
    }
    return $result
}

# ============================================================
# MODE: LIST APPS
# ============================================================
if ($PSCmdlet.ParameterSetName -eq 'ListApps') {
    $regKey = Get-Item -Path 'HKLM:\SOFTWARE\RegisteredApplications' -ErrorAction SilentlyContinue
    if (-not $regKey) {
        Write-Error 'HKLM:\SOFTWARE\RegisteredApplications not found.'
        exit 1
    }
    $names = $regKey.GetValueNames() | Where-Object { $_ } | Sort-Object
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
    $appsKey = Get-Item -Path 'HKLM:\SOFTWARE\RegisteredApplications' -ErrorAction SilentlyContinue
    if (-not $appsKey) {
        Write-Error 'HKLM:\SOFTWARE\RegisteredApplications not found.'
        exit 1
    }

    $capRelPath = $appsKey.GetValue($App)
    if (-not $capRelPath) {
        Write-Error ('Application not found: {0}' -f $App)
        Write-ConsoleInfo 'Run with -ListApps to see available application names.'
        exit 1
    }
    Write-ConsoleDetail ('Capabilities subkey: {0}' -f $capRelPath)

    $capPath = Resolve-CapabilitiesPath -RawPath $capRelPath
    if (-not $capPath) {
        Write-Error ('Capabilities registry key not found for: {0}{1}  Raw path from registry: {2}' -f $App, [Environment]::NewLine, $capRelPath)
        exit 1
    }

    $results = [System.Collections.Generic.List[PSObject]]::new()

    # File associations
    $fileAssocPath = Join-Path $capPath 'FileAssociations'
    if (Test-Path $fileAssocPath) {
        $values = Get-RegistryValues -KeyPath $fileAssocPath
        foreach ($ext in ($values.Keys | Sort-Object)) {
            $results.Add([PSCustomObject]@{
                Type        = 'Extension'
                Association = $ext
                ProgID      = $values[$ext]
            })
        }
        Write-ConsoleDetail ('{0} file association(s) found.' -f $values.Count)
    } else {
        Write-ConsoleDetail 'No FileAssociations subkey found.'
    }

    # URL / protocol associations
    $urlAssocPath = Join-Path $capPath 'URLAssociations'
    if (Test-Path $urlAssocPath) {
        $values = Get-RegistryValues -KeyPath $urlAssocPath
        foreach ($proto in ($values.Keys | Sort-Object)) {
            $results.Add([PSCustomObject]@{
                Type        = 'Protocol'
                Association = $proto
                ProgID      = $values[$proto]
            })
        }
        Write-ConsoleDetail ('{0} URL association(s) found.' -f $values.Count)
    } else {
        Write-ConsoleDetail 'No URLAssociations subkey found.'
    }

    if ($results.Count -eq 0) {
        Write-Warning ('No associations found for: {0}' -f $App)
        exit 0
    }

    Write-ConsoleInfo ('{0} association(s) found for: {1}' -f $results.Count, $App)
    $results | Sort-Object Type, Association | Write-Output
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
                $results.Add([PSCustomObject]@{
                    Association = $extKey.PSChildName
                    ProgID      = if ($progID) { $progID } else { '' }
                })
            }
        }

    if ($results.Count -eq 0) {
        Write-Warning ('No extensions found for category: {0}' -f $Category)
        Write-ConsoleInfo 'Run with -ListCategories to see available categories.'
        exit 0
    }

    Write-ConsoleInfo ('{0} extension(s) found for category: {1}' -f $results.Count, $Category)
    $results | Sort-Object Association | Write-Output
    exit 0
}
