# Copyright (C) Chemin-Neuf IT Team
# SPDX-License-Identifier: GPL-3.0-only
# Full license text: see LICENSE at the repository root
<#
.SYNOPSIS
    Sets the Windows UCPD (UserChoice Protection Driver) service start type.

.DESCRIPTION
    Configures the start type of the UCPD service that protects default application
    UserChoice registry keys from third-party modification. Requires administrator rights.
    Reports the state before and after the change. A reboot is required for any change
    to take full effect. When disabling, a stop of the running driver is attempted;
    kernel-mode drivers typically cannot be stopped without a reboot, so the stop attempt
    may fail gracefully and a reboot reminder is always emitted.
    Results are logged to a logs\ subfolder next to the script, with fallback to %TEMP%.

.PARAMETER StartType
    Target start type for the UCPD service.
    Disabled - Sets start type to Disabled and attempts to stop the running driver
               immediately. A reboot is required if the stop attempt fails.
    Default  - Restores the Windows default start type (Automatic). A reboot is
               required for the driver to load if it is not already running.

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
    .\set-ucpd-service.ps1 -StartType Disabled

    Disables the UCPD service and attempts to stop it immediately.

.EXAMPLE
    .\set-ucpd-service.ps1 -StartType Default

    Restores the UCPD service to the Windows default start type (Automatic).

.EXAMPLE
    .\set-ucpd-service.ps1 -StartType Disabled -WhatIf

    Shows what would be changed without applying anything.

.NOTES
    File:           set-ucpd-service.ps1
    Version:        see $scriptVersion below (single source of truth)
    Author:         Claude Sonnet 4.6 (GitHub Copilot)
    License:        GPL-3.0-only
    Prerequisites:  PowerShell 5.1+; administrator rights required

.LINK
    https://github.com/Chemin-Neuf/pc-set-default-applications
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Disabled', 'Default')]
    [string]$StartType,

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
$scriptVersion = '1.0.1'
if ($Version) {
    Write-Host ('set-ucpd-service.ps1  v{0}' -f $scriptVersion)
    exit 0
}

# ============================================================
# CONFIGURATION
# ============================================================
$ucpdServiceName      = 'UCPD'
$ucpdRegistryPath     = 'HKLM:\SYSTEM\CurrentControlSet\Services\UCPD'

# Windows default start type for UCPD.sys.
# Verify against a clean machine using get-ucpd-status.ps1 before changing this value.
# sc.exe token: 'boot'=0, 'system'=1, 'auto'=2, 'demand'=3, 'disabled'=4
$ucpdDefaultScToken   = 'auto'   # Automatic
$ucpdDefaultStartDword = 2       # must match $ucpdDefaultScToken above

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

# ============================================================
# LOGGING
# ============================================================
Initialize-Log -ScriptName 'set-ucpd-service' -Version $scriptVersion
Initialize-ConsoleEncoding

# ============================================================
# ELEVATION CHECK
# ============================================================
if (-not (Test-AdminPrivilege)) {
    Write-ErrorLog 'This script requires administrator rights.'
    Write-ErrorLog ('Re-run from an elevated PowerShell prompt: .\set-ucpd-service.ps1 -StartType {0}' -f $StartType)
    exit 1
}

# ============================================================
# FUNCTIONS
# ============================================================

<#
.SYNOPSIS
    Translates a service Start DWORD to a readable label.

.PARAMETER StartDword
    Integer value of the Start registry entry.
#>
function Get-StartTypeLabel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [int]$StartDword
    )
    switch ($StartDword) {
        0       { return 'Boot'      }
        1       { return 'System'    }
        2       { return 'Automatic' }
        3       { return 'Manual'    }
        4       { return 'Disabled'  }
        default { return ('Unknown ({0})' -f $StartDword) }
    }
}

<#
.SYNOPSIS
    Reads the current start type and running status of the UCPD service from the registry
    and the Service Control Manager.

.OUTPUTS
    PSCustomObject with StartTypeDword, StartTypeLabel, and RunningStatus.
#>
function Get-UcpdCurrentState {
    [CmdletBinding()]
    param()

    $state = [PSCustomObject]@{
        StartTypeDword = $null
        StartTypeLabel = 'N/A'
        RunningStatus  = 'N/A'
    }

    try {
        $startDword            = (Get-ItemProperty -Path $ucpdRegistryPath -Name 'Start' -ErrorAction Stop).Start
        $state.StartTypeDword  = $startDword
        $state.StartTypeLabel  = Get-StartTypeLabel -StartDword $startDword
    }
    catch {
        Write-Detail ('Could not read UCPD Start registry value: {0}' -f $_.Exception.Message)
    }

    try {
        $svc                  = Get-Service -Name $ucpdServiceName -ErrorAction Stop
        $state.RunningStatus  = $svc.Status.ToString()
    }
    catch {
        Write-Detail ('Get-Service could not query UCPD: {0}' -f $_.Exception.Message)
        $state.RunningStatus = 'Not found by SCM'
    }

    return $state
}

# ============================================================
# MAIN
# ============================================================
Write-Info ('set-ucpd-service.ps1 v{0} starting' -f $scriptVersion)
Write-Detail ('Log file: {0}' -f $Global:LogFile)
Write-Info ('Requested start type: {0}' -f $StartType)

# --- Verify service is registered ---
if (-not (Test-Path $ucpdRegistryPath)) {
    Write-Warn 'UCPD service is not registered on this machine. Nothing to do.'
    exit 0
}

# --- Before state ---
$before = Get-UcpdCurrentState
Write-Info ('Before - Start type: {0} | Status: {1}' -f $before.StartTypeLabel, $before.RunningStatus)

# --- Resolve target values ---
$targetScToken   = if ($StartType -eq 'Disabled') { 'disabled' } else { $ucpdDefaultScToken }
$targetStartDword = if ($StartType -eq 'Disabled') { 4 } else { $ucpdDefaultStartDword }

# --- Skip if already at target ---
if ($before.StartTypeDword -eq $targetStartDword) {
    Write-Info ('UCPD service start type is already {0}. No change needed.' -f $before.StartTypeLabel)
    if ($StartType -eq 'Disabled' -and $before.RunningStatus -eq 'Running') {
        Write-Warn 'The driver is still running. A reboot is required for it to stop.'
    }
    exit 0
}

# --- Apply change ---
$changeApplied = $false

if ($PSCmdlet.ShouldProcess(
    ('UCPD service - start type: {0} -> {1}' -f $before.StartTypeLabel, $StartType),
        'Set')) {

    Write-Info ('Setting UCPD service start type to {0}...' -f $StartType)
    try {
        $scOutput = & sc.exe config $ucpdServiceName start= $targetScToken 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-ErrorLog ('sc.exe config failed (exit code {0}): {1}' -f $LASTEXITCODE, ($scOutput -join ' '))
            exit 1
        }
        Write-Detail ('sc.exe output: {0}' -f ($scOutput -join ' '))
        Write-Success ('UCPD service start type set to {0}.' -f $StartType)
        $changeApplied = $true
    }
    catch {
        Write-ErrorLog ('Failed to configure UCPD service: {0}' -f $_.Exception.Message)
        exit 1
    }

    # --- Attempt immediate stop when disabling ---
    if ($StartType -eq 'Disabled' -and $before.RunningStatus -eq 'Running') {
        Write-Info 'Attempting to stop the UCPD driver (kernel drivers may require a reboot to stop)...'
        try {
            Stop-Service -Name $ucpdServiceName -Force -ErrorAction Stop
            Write-Success 'UCPD driver stopped successfully.'
        }
        catch {
            Write-Warn ('Could not stop the running UCPD driver: {0}' -f $_.Exception.Message)
            Write-Warn 'A reboot is required for the driver to stop.'
        }
    }
}

# --- After state and reboot reminder ---
if ($changeApplied) {
    $after = Get-UcpdCurrentState
    Write-Info ('After  - Start type: {0} | Status: {1}' -f $after.StartTypeLabel, $after.RunningStatus)
    Write-Warn 'A reboot is required for this change to take full effect.'
}

exit 0
