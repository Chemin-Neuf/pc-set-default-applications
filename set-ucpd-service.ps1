# Copyright (C) Chemin-Neuf IT Team
# SPDX-License-Identifier: GPL-3.0-only
# Full license text: see LICENSE at the repository root

<#
.SYNOPSIS
    Sets the Windows UCPD (UserChoice Protection Driver) state.

.DESCRIPTION
    Changes the effective state of the UCPD protection mechanism that protects default
    application UserChoice registry keys from third-party modification. Requires
    administrator rights. This includes configuring the service start type and, when
    disabling, attempting to stop the running driver immediately. Reports the state
    before and after the change. A reboot is required for any change to take full
    effect. When disabling, a stop of the running driver is attempted;
    kernel-mode drivers typically cannot be stopped without a reboot, so the stop attempt
    may fail gracefully and a reboot reminder is always emitted.
    Results are logged to a logs\ subfolder next to the script, with fallback to %TEMP%.

.PARAMETER State
    Target UCPD state.
    Disabled - Configures the service start type to Disabled and attempts to stop the
               running driver immediately. A reboot is required if the stop attempt fails.
    Default  - Restores the Windows default configuration (Automatic start type). A reboot
               is required for the driver to load if it is not already running.

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
    .\set-ucpd-service.ps1 -State Disabled

    Disables the UCPD service and attempts to stop it immediately.

.EXAMPLE
    .\set-ucpd-service.ps1 -State Default

    Restores the UCPD service to the Windows default start type (Automatic).

.NOTES
    File:           set-ucpd-service.ps1
    Version:        3.0.0
    Author:         Claude Sonnet 4.6 (GitHub Copilot)
    License:        GPL-3.0-only
    Prerequisites:  PowerShell 5.1+; administrator rights required

.LINK
    https://github.com/Chemin-Neuf/pc-set-default-applications
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Disabled', 'Default')]
    [string]$State,

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
$scriptVersion = '3.0.0'
if ($Version) {
    Write-Host ('set-ucpd-service.ps1  v{0}' -f $scriptVersion)
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

$ucpdUtilsPath = Join-Path $PSScriptRoot 'UcpdUtils.psm1'
if (-not (Test-Path $ucpdUtilsPath)) {
    Write-Error ('UcpdUtils.psm1 not found at: {0}' -f $ucpdUtilsPath)
    exit 1
}
Import-Module $ucpdUtilsPath -Force

# ============================================================
# LOGGING
# ============================================================
Initialize-Log -ScriptName 'set-ucpd-service' -Version $scriptVersion
Initialize-ConsoleEncoding

# ============================================================
# MAIN
# ============================================================
Write-Info ('set-ucpd-service.ps1 v{0} starting' -f $scriptVersion)
Write-Detail ('Log file: {0}' -f $Global:LogFile)
Write-Info ('Requested state: {0}' -f $State)

$before = Get-UcpdStatus
Write-Info ('Before - Start type: {0} | Status: {1}' -f $before.StartTypeLabel, $before.RunningStatus)

$result = Set-UcpdState -State $State

if (-not $result.Success) {
    switch ($result.Reason) {
        'NotAdmin' {
            Write-ErrorLog $result.Message
            Write-ErrorLog ('Re-run from an elevated PowerShell prompt: .\set-ucpd-service.ps1 -State {0}' -f $State)
            exit 1
        }
        'ConfigFailed' {
            Write-ErrorLog $result.Message
            exit 1
        }
        default {
            Write-ErrorLog $result.Message
            exit 1
        }
    }
}

switch ($result.Reason) {
    'NotRegistered'  { Write-Warn  $result.Message }
    'AlreadyAtTarget'{
        Write-Info $result.Message
        if ($result.RequiresReboot) { Write-Warn 'A reboot is required for the driver to stop.' }
    }
    'Stopped'        {
        $after = Get-UcpdStatus
        Write-Success $result.Message
        Write-Info ('After  - Start type: {0} | Status: {1}' -f $after.StartTypeLabel, $after.RunningStatus)
    }
    'RequiresReboot' {
        $after = Get-UcpdStatus
        Write-Success ('UCPD state set to {0}.' -f $State)
        Write-Info ('After  - Start type: {0} | Status: {1}' -f $after.StartTypeLabel, $after.RunningStatus)
        Write-Warn $result.Message
    }
    default          { Write-Info $result.Message }
}

exit 0