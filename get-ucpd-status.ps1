# Copyright (C) Chemin-Neuf IT Team
# SPDX-License-Identifier: GPL-3.0-only
# Full license text: see LICENSE at the repository root
<#
.SYNOPSIS
    Reports the current state of the UCPD (UserChoice Protection Driver) on this machine.

.DESCRIPTION
    Checks the UCPD.sys driver file presence, whether the associated Windows service is
    registered, its configured start type, and its current running status. Also reports
    whether the session has administrator rights (required to change the state with
    set-ucpd-service.ps1). Produces a color-coded report with OK/WARNING/ERROR indicators
    so administrators can quickly assess whether UCPD may interfere with setting default
    applications. No changes are made; the script is entirely read-only.
    Results are logged to a logs\ subfolder next to the script, with fallback to %TEMP%.

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
    .\get-ucpd-status.ps1

    Displays UCPD status with default verbosity.

.EXAMPLE
    .\get-ucpd-status.ps1 -Verbosity Detailed

    Displays UCPD status with full detail output including registry values.

.EXAMPLE
    .\get-ucpd-status.ps1 -Quiet -LogVerbosity Detailed

    Runs silently and writes full detail to the log file only.

.NOTES
    File:           get-ucpd-status.ps1
    Version:        see $scriptVersion below (single source of truth)
    Author:         Claude Sonnet 4.6 (GitHub Copilot)
    License:        GPL-3.0-only
    Prerequisites:  PowerShell 5.1+; no administrator rights required

.LINK
    https://github.com/Chemin-Neuf/pc-set-default-applications
#>

[CmdletBinding()]
param(
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
# Single source of truth for this script version.
$scriptVersion = '1.0.0'
if ($Version) {
    Write-Host ('get-ucpd-status.ps1  v{0}' -f $scriptVersion)
    exit 0
}

# ============================================================
# CONFIGURATION
# ============================================================
$ucpdDriverPath   = Join-Path $env:SystemRoot 'System32\drivers\UCPD.sys'
$ucpdServiceName  = 'UCPD'
$ucpdRegistryPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\UCPD'

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
Initialize-Log -ScriptName 'get-ucpd-status' -Version $scriptVersion

# ============================================================
# FUNCTIONS
# ============================================================

<#
.SYNOPSIS
    Writes a single check result line to the console and the log.

.PARAMETER Label
    Short description of what was checked.

.PARAMETER Value
    The observed value or outcome.

.PARAMETER Status
    Severity of the result: OK, WARNING, ERROR, or UNKNOWN.
#>
function Write-CheckResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Label,

        [Parameter(Mandatory=$true)]
        [string]$Value,

        [Parameter(Mandatory=$true)]
        [ValidateSet('OK', 'WARNING', 'ERROR', 'UNKNOWN')]
        [string]$Status
    )

    $sym = Get-StatusSymbol -Status $Status
    if ($Global:ConsoleVerbosity -ne 'None') {
        Write-Host ('{0} {1}: {2}' -f $sym.Symbol, $Label, $Value) -ForegroundColor $sym.Color
    }

    $logLevel = switch ($Status) {
        'OK'      { 'INFO'  }
        'ERROR'   { 'ERROR' }
        'WARNING' { 'WARN'  }
        default   { 'INFO'  }
    }
    Write-Log ('{0} | {1}: {2}' -f $Status, $Label, $Value) -Level $logLevel
}

# ============================================================
# MAIN
# ============================================================
Write-Info ('get-ucpd-status.ps1 v{0} starting' -f $scriptVersion)
Write-Detail ('Log file: {0}' -f $Global:LogFile)

if ($Global:ConsoleVerbosity -ne 'None') {
    Write-Host ''
    Write-Host 'UCPD (UserChoice Protection Driver) Status' -ForegroundColor Cyan
    Write-Host ('=' * 50) -ForegroundColor DarkGray
}

$overallStatus = 'OK'

# --- Check 1: Administrator privilege (informational) ---
$isAdmin = Test-AdminPrivilege
if ($isAdmin) {
    Write-CheckResult -Label 'Running as administrator' -Value 'Yes' -Status 'OK'
}
else {
    Write-CheckResult -Label 'Running as administrator' `
                      -Value 'No — set-ucpd-service.ps1 requires elevation to make changes' `
                      -Status 'WARNING'
    if ($overallStatus -eq 'OK') { $overallStatus = 'WARNING' }
}

# --- Check 2: Driver file present ---
$driverPresent = Test-Path $ucpdDriverPath
if ($driverPresent) {
    $driverVersion = (Get-Item $ucpdDriverPath -ErrorAction SilentlyContinue).VersionInfo.FileVersion
    Write-CheckResult -Label 'Driver file present' `
                      -Value ('Yes — {0} (v{1})' -f $ucpdDriverPath, $driverVersion) `
                      -Status 'WARNING'
    if ($overallStatus -eq 'OK') { $overallStatus = 'WARNING' }
}
else {
    Write-CheckResult -Label 'Driver file present' `
                      -Value ('No — {0}' -f $ucpdDriverPath) `
                      -Status 'OK'
}

# --- Check 3: Service registered ---
$serviceRegistered = Test-Path $ucpdRegistryPath
if ($serviceRegistered) {
    Write-CheckResult -Label 'Service registered' -Value 'Yes' -Status 'WARNING'
    if ($overallStatus -eq 'OK') { $overallStatus = 'WARNING' }
}
else {
    Write-CheckResult -Label 'Service registered' -Value 'No' -Status 'OK'
}

# --- Check 4: Configured start type ---
if ($serviceRegistered) {
    $startTypeRaw = $null
    try {
        $startTypeRaw = (Get-ItemProperty -Path $ucpdRegistryPath -Name 'Start' -ErrorAction Stop).Start
    }
    catch {
        Write-Detail ('Could not read Start value from registry: {0}' -f $_.Exception.Message)
    }

    if ($null -ne $startTypeRaw) {
        $startTypeLabel = switch ($startTypeRaw) {
            0       { 'Boot'      }
            1       { 'System'    }
            2       { 'Automatic' }
            3       { 'Manual'    }
            4       { 'Disabled'  }
            default { ('Unknown ({0})' -f $startTypeRaw) }
        }
        $startStatus = switch ($startTypeRaw) {
            { $_ -in 0, 1, 2 } { 'ERROR'   }
            3                  { 'WARNING' }
            4                  { 'OK'      }
            default            { 'UNKNOWN' }
        }
        Write-CheckResult -Label 'Service start type' -Value $startTypeLabel -Status $startStatus
        if ($startStatus -eq 'ERROR' -and $overallStatus -ne 'ERROR') { $overallStatus = 'ERROR' }
        elseif ($startStatus -eq 'WARNING' -and $overallStatus -eq 'OK') { $overallStatus = 'WARNING' }
    }
    else {
        Write-CheckResult -Label 'Service start type' -Value 'Could not read' -Status 'UNKNOWN'
    }
}
else {
    Write-Detail 'Skipping start type check — service not registered.'
}

# --- Check 5: Current running status ---
if ($serviceRegistered) {
    $svc = $null
    try {
        $svc = Get-Service -Name $ucpdServiceName -ErrorAction Stop
    }
    catch {
        Write-Detail ('Get-Service could not query UCPD: {0}' -f $_.Exception.Message)
    }

    if ($null -ne $svc) {
        $runStatus = if ($svc.Status -eq 'Running') { 'ERROR' } else { 'OK' }
        Write-CheckResult -Label 'Service current status' -Value $svc.Status -Status $runStatus
        if ($runStatus -eq 'ERROR') { $overallStatus = 'ERROR' }
    }
    else {
        Write-CheckResult -Label 'Service current status' -Value 'Could not determine' -Status 'UNKNOWN'
    }
}
else {
    Write-Detail 'Skipping running status check — service not registered.'
}

# --- Summary ---
$summarySymbol  = Get-StatusSymbol -Status $overallStatus
$summaryMessage = switch ($overallStatus) {
    'OK'      { 'UCPD is not active. No interference expected with default application settings.' }
    'WARNING' { 'UCPD is present but not actively running. SetUserFTA 1.8.4+ handles this correctly.' }
    'ERROR'   { 'UCPD is active. Use SetUserFTA 1.8.4+ or run set-ucpd-service.ps1 -StartType Disabled (requires admin + reboot).' }
    default   { 'UCPD status could not be fully determined.' }
}

if ($Global:ConsoleVerbosity -ne 'None') {
    Write-Host ('=' * 50) -ForegroundColor DarkGray
    Write-Host ('{0} {1}' -f $summarySymbol.Symbol, $summaryMessage) -ForegroundColor $summarySymbol.Color
    Write-Host ''
}

$summaryLogLevel = switch ($overallStatus) {
    'OK'    { 'SUCCESS' }
    'ERROR' { 'ERROR'   }
    default { 'WARN'    }
}
Write-Log ('Summary: {0} — {1}' -f $overallStatus, $summaryMessage) -Level $summaryLogLevel

exit 0
