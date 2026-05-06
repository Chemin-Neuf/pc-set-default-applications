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
    export findings directly. Per-run logging follows -LogVerbosity and defaults
    to Detailed. Version: see $scriptVersion in the script body.

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
    Controls log file output level: None, Normal, or Detailed (default: Detailed).

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
    [string]$LogVerbosity = 'Detailed',

    [Parameter()]
    [switch]$Quiet,

    [Parameter()]
    [switch]$Version
)

# ============================================================
# VERSION
# ============================================================
$scriptVersion = '3.6.0'
if ($Version) {
    Write-Host ('get-application-associations.ps1  v{0}' -f $scriptVersion)
    exit 0
}

if ($Quiet) { $Verbosity = 'None' }

# ============================================================
# GLOBALS
# ============================================================
$Global:ConsoleVerbosity = $Verbosity
$Global:LogVerbosity     = $LogVerbosity

$exportCsvPath = $null
if ($ExportCsv) {
    $exportCsvPath = $ExportCsv
}

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

# ============================================================
# LOGGING
# ============================================================
Initialize-Log -ScriptName 'get-application-associations' -Version $scriptVersion
Initialize-ConsoleEncoding

# ============================================================
# HELPERS
# ============================================================

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

    $found = foreach ($registeredApplication in $RegisteredApplications.Values) {
        $resolvedApplication = Resolve-RegisteredApplication -RegisteredApplication $registeredApplication
        if ($resolvedApplication.DisplayName -eq $Application -or
            (Remove-TrailingVersion -Name $resolvedApplication.DisplayName) -eq $Application) {
            $resolvedApplication
        }
    }

    return @($found | Sort-Object RegisteredName)
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

    # Exclude AppX entries that did not resolve to a friendly name (DisplayName still equals
    # the raw registered name, which is an auto-generated hash starting with AppX).
    $resolvedApplications = @($resolvedApplications | Where-Object {
        -not ($_.RegisteredName -like 'AppX*' -and $_.DisplayName -eq $_.RegisteredName)
    })

    $results = foreach ($group in ($resolvedApplications | Group-Object DisplayName | Sort-Object Name)) {
        [PSCustomObject]@{
            Application            = $group.Name
            RegisteredApplications = ($group.Group | Sort-Object RegisteredName | ForEach-Object { $_.RegisteredName }) -join '; '
        }
    }

    # Strip trailing version numbers when the base name is unique across all results.
    # Example: "GIMP 3.2.4" → "GIMP" when no other entry strips to "GIMP".
    # "MuseScore 3" and "MuseScore 4" both strip to "MuseScore" → both keep their original name.
    $baseNameCounts = @{}
    foreach ($result in $results) {
        $baseName = Remove-TrailingVersion -Name $result.Application
        if (-not $baseNameCounts.ContainsKey($baseName)) { $baseNameCounts[$baseName] = 0 }
        $baseNameCounts[$baseName]++
    }
    $results = foreach ($result in $results) {
        $baseName = Remove-TrailingVersion -Name $result.Application
        if ($baseNameCounts[$baseName] -eq 1 -and $baseName -ne $result.Application) {
            [PSCustomObject]@{
                Application            = $baseName
                RegisteredApplications = $result.RegisteredApplications
            }
        } else {
            $result
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
    Returns the version-stripped friendly name for a display name, when the stripped
    name is unique across all registered applications.

.PARAMETER DisplayName
    Full display name (e.g. "GIMP 3.2.4").

.PARAMETER RegisteredApplications
    Hashtable returned by Get-RegisteredApplications.
#>
function Resolve-EffectiveFriendlyName {
    param(
        [Parameter(Mandatory=$true)][string]$DisplayName,
        [Parameter(Mandatory=$true)][hashtable]$RegisteredApplications
    )
    $baseName = Remove-TrailingVersion -Name $DisplayName
    if ($baseName -eq $DisplayName) { return $DisplayName }
    foreach ($app in $RegisteredApplications.Values) {
        $resolved = Resolve-RegisteredApplication -RegisteredApplication $app
        if ($resolved.DisplayName -ne $DisplayName -and
            (Remove-TrailingVersion -Name $resolved.DisplayName) -eq $baseName) {
            return $DisplayName   # collision — keep original name
        }
    }
    return $baseName
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
        Write-ErrorLog ('Output directory does not exist: {0}' -f $parentDir)
        return $false
    }
    if ((Test-Path $resolvedPath) -and -not $Overwrite) {
        Write-ErrorLog ('Output file already exists: {0}. Use -OverwriteCsv to replace it.' -f $resolvedPath)
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
    Write-Info ('CSV written: {0}' -f $resolvedPath)
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
        Write-Info ('{0} friendly application name(s) found across {1} registered entry/entries:' -f $friendlyApplications.Count, $registeredApplications.Count)
        if ($Verbosity -ne 'None') {
            $friendlyApplications | Format-Table -AutoSize | Out-String | Write-Host
        }
        $friendlyApplications | Write-Output
        exit 0
    }

    $names = $registeredApplications.Keys | Sort-Object
    if (-not $names) {
        Write-Warning 'No registered applications found.'
        exit 0
    }
    Write-Info ('{0} registered application(s):' -f @($names).Count)
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
    Write-Info ('{0} category/categories found:' -f @($categories).Count)
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
        Write-Info 'Run with -ListApps or -ListAppsRaw to see available application names.'
        exit 1
    }

    $displayName = Resolve-EffectiveFriendlyName -DisplayName $selectedApplications[0].DisplayName -RegisteredApplications $registeredApplications

    $results = [System.Collections.Generic.List[PSObject]]::new()
    $seenAssociations = @{}

    foreach ($selectedApplication in $selectedApplications) {
        if (-not $selectedApplication.CapabilitiesPath) {
            Write-Detail ('Skipping ''{0}'': capabilities registry key not found. Raw path from registry: {1}' -f $selectedApplication.RegisteredName, $selectedApplication.CapabilitiesRawPath)
            continue
        }

        Write-Detail ('Capabilities subkey for ''{0}'': {1}' -f $selectedApplication.RegisteredName, $selectedApplication.CapabilitiesRawPath)

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
            Write-Detail ('{0} file association(s) found for ''{1}''.' -f $values.Count, $selectedApplication.RegisteredName)
        } else {
            Write-Detail ('No FileAssociations subkey found for ''{0}''.' -f $selectedApplication.RegisteredName)
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
            Write-Detail ('{0} URL association(s) found for ''{1}''.' -f $values.Count, $selectedApplication.RegisteredName)
        } else {
            Write-Detail ('No URLAssociations subkey found for ''{0}''.' -f $selectedApplication.RegisteredName)
        }
    }

    if ($results.Count -eq 0) {
        Write-Warning ('No associations found for: {0}' -f $App)
        exit 0
    }

    Write-Info ('{0} association(s) found for: {1}' -f $results.Count, $displayName)
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
        Write-Info 'Run with -ListCategories to see available categories.'
        exit 0
    }

    $catRegisteredApplications = Get-RegisteredApplications   # already cached
    foreach ($result in $results) {
        if ($result.Application) {
            $result.Application = Resolve-EffectiveFriendlyName -DisplayName $result.Application -RegisteredApplications $catRegisteredApplications
        }
    }

    Write-Info ('{0} extension(s) found for category: {1}' -f $results.Count, $Category)
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
