<#
  Copyright (C) Chemin-Neuf IT Team
  SPDX-License-Identifier: GPL-3.0-only
  Full license text: see LICENSE at the repository root
#>
# Original Author: Claude Sonnet 4.6 (GitHub Copilot)
<#
.SYNOPSIS
    Shared UCPD (UserChoice Protection Driver) functions for the pc-set-default-applications toolset.

.DESCRIPTION
    Provides Get-UcpdStatus and Set-UcpdState for reading and changing the UCPD driver state.
    Consumed by get-ucpd-status.ps1, set-ucpd-service.ps1, and set-default-applications.ps1.
    Never calls exit. Returns structured PSCustomObjects so callers can decide how to handle results.
#>

# ============================================================
# CONFIGURATION (module-level constants)
# ============================================================
$script:ucpdDriverPath      = Join-Path $env:SystemRoot 'System32\drivers\UCPD.sys'
$script:ucpdServiceName     = 'UCPD'
$script:ucpdRegistryPath    = 'HKLM:\SYSTEM\CurrentControlSet\Services\UCPD'
$script:ucpdDefaultScToken  = 'auto'   # sc.exe token for Automatic
$script:ucpdDefaultStartDword = 2      # must match $script:ucpdDefaultScToken

# ============================================================
# PRIVATE HELPERS
# ============================================================

<#
.SYNOPSIS
    Translates a service Start DWORD to a readable label.
#>
function Get-UcpdStartTypeLabel {
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

# ============================================================
# PUBLIC FUNCTIONS
# ============================================================

<#
.SYNOPSIS
    Returns the current UCPD driver and service status as a structured object.

.OUTPUTS
    PSCustomObject with:
      IsActive         - [bool]   $true when driver is present, service registered, and running.
      ServiceRegistered- [bool]   $true when the UCPD registry key exists.
      DriverPresent    - [bool]   $true when UCPD.sys exists on disk.
      StartTypeDword   - [int]    Raw Start DWORD from registry, or $null if unreadable.
      StartTypeLabel   - [string] Human-readable start type.
      RunningStatus    - [string] Current SCM status string (e.g. 'Running', 'Stopped').
      IsAdmin          - [bool]   $true when the current session is elevated.
#>
function Get-UcpdStatus {
    [CmdletBinding()]
    param()

    $result = [PSCustomObject]@{
        IsActive          = $false
        ServiceRegistered = $false
        DriverPresent     = $false
        StartTypeDword    = $null
        StartTypeLabel    = 'N/A'
        RunningStatus     = 'N/A'
        IsAdmin           = $false
    }

    $result.IsAdmin          = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $result.DriverPresent    = Test-Path $script:ucpdDriverPath
    $result.ServiceRegistered = Test-Path $script:ucpdRegistryPath

    if ($result.ServiceRegistered) {
        try {
            $startDword              = (Get-ItemProperty -Path $script:ucpdRegistryPath -Name 'Start' -ErrorAction Stop).Start
            $result.StartTypeDword   = $startDword
            $result.StartTypeLabel   = Get-UcpdStartTypeLabel -StartDword $startDword
        }
        catch {
            Write-Detail ('UCPD: Could not read Start registry value: {0}' -f $_.Exception.Message)
        }

        try {
            $svc                  = Get-Service -Name $script:ucpdServiceName -ErrorAction Stop
            $result.RunningStatus = $svc.Status.ToString()
        }
        catch {
            Write-Detail ('UCPD: Get-Service could not query UCPD: {0}' -f $_.Exception.Message)
            $result.RunningStatus = 'Not found by SCM'
        }
    }

    # IsActive: driver file present AND service not disabled AND currently running
    $result.IsActive = (
        $result.DriverPresent -and
        $result.ServiceRegistered -and
        $result.RunningStatus -eq 'Running'
    )

    return $result
}

<#
.SYNOPSIS
    Configures the UCPD service start type and optionally stops the running driver.

.PARAMETER State
    Target UCPD state: Disabled or Default.

.OUTPUTS
    PSCustomObject with:
      Success         - [bool]   $true when the configuration change was applied.
      Reason          - [string] NotAdmin | NotRegistered | AlreadyAtTarget | ConfigFailed |
                                 RequiresReboot | Stopped | Error
      RequiresReboot  - [bool]   $true when a reboot is needed for the change to fully take effect.
      Message         - [string] Human-readable summary for logging or display.
#>
function Set-UcpdState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('Disabled', 'Default')]
        [string]$State
    )

    $result = [PSCustomObject]@{
        Success        = $false
        Reason         = 'Error'
        RequiresReboot = $false
        Message        = ''
    }

    # Elevation check
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        $result.Reason  = 'NotAdmin'
        $result.Message = 'Administrator rights are required to change the UCPD state.'
        return $result
    }

    # Service must be registered
    if (-not (Test-Path $script:ucpdRegistryPath)) {
        $result.Success = $true
        $result.Reason  = 'NotRegistered'
        $result.Message = 'UCPD service is not registered on this machine. Nothing to do.'
        return $result
    }

    # Read current state
    $currentStartDword = $null
    try {
        $currentStartDword = (Get-ItemProperty -Path $script:ucpdRegistryPath -Name 'Start' -ErrorAction Stop).Start
    }
    catch {
        Write-Detail ('UCPD: Could not read Start registry value: {0}' -f $_.Exception.Message)
    }

    $currentRunningStatus = 'N/A'
    try {
        $svc                  = Get-Service -Name $script:ucpdServiceName -ErrorAction Stop
        $currentRunningStatus = $svc.Status.ToString()
    }
    catch {
        $currentRunningStatus = 'Not found by SCM'
    }

    $targetScToken    = if ($State -eq 'Disabled') { 'disabled' } else { $script:ucpdDefaultScToken }
    $targetStartDword = if ($State -eq 'Disabled') { 4 } else { $script:ucpdDefaultStartDword }

    # Already at target
    if ($currentStartDword -eq $targetStartDword) {
        $result.Success = $true
        $result.Reason  = 'AlreadyAtTarget'
        if ($State -eq 'Disabled' -and $currentRunningStatus -eq 'Running') {
            $result.RequiresReboot = $true
            $result.Message = 'UCPD is already configured as Disabled but the driver is still running. A reboot is required.'
        }
        else {
            $result.Message = ('UCPD is already configured as {0}. No change needed.' -f $State)
        }
        return $result
    }

    # Apply sc.exe change
    Write-Detail ('UCPD: Applying state {0} via sc.exe...' -f $State)
    try {
        $scOutput = & sc.exe config $script:ucpdServiceName start= $targetScToken 2>&1
        if ($LASTEXITCODE -ne 0) {
            $result.Reason  = 'ConfigFailed'
            $result.Message = ('sc.exe config failed (exit {0}): {1}' -f $LASTEXITCODE, ($scOutput -join ' '))
            return $result
        }
        Write-Detail ('UCPD: sc.exe output: {0}' -f ($scOutput -join ' '))
    }
    catch {
        $result.Reason  = 'Error'
        $result.Message = ('Failed to configure UCPD service: {0}' -f $_.Exception.Message)
        return $result
    }

    $result.Success = $true

    # Attempt immediate stop when disabling
    if ($State -eq 'Disabled' -and $currentRunningStatus -eq 'Running') {
        Write-Detail 'UCPD: Attempting to stop the running driver...'
        try {
            Stop-Service -Name $script:ucpdServiceName -Force -ErrorAction Stop
            $result.Reason         = 'Stopped'
            $result.RequiresReboot = $false
            $result.Message        = 'UCPD configured as Disabled and driver stopped successfully.'
        }
        catch {
            $result.Reason         = 'RequiresReboot'
            $result.RequiresReboot = $true
            $result.Message        = ('UCPD configured as Disabled. Driver stop failed (kernel drivers require a reboot): {0}' -f $_.Exception.Message)
        }
    }
    else {
        $result.Reason         = 'RequiresReboot'
        $result.RequiresReboot = $true
        $result.Message        = ('UCPD state set to {0}. A reboot is required for this change to take full effect.' -f $State)
    }

    return $result
}

Export-ModuleMember -Function Get-UcpdStatus, Set-UcpdState