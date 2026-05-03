<#
  Copyright (C) Chemin-Neuf IT Team
  SPDX-License-Identifier: GPL-3.0-only
  Full license text: see LICENSE at the repository root
#>
# Original Author: Claude 3.5 Sonnet (Anthropic / GitHub Copilot)
# Major Contributors: GPT-5.4 (GitHub Copilot)

<#
.SYNOPSIS
    Appends a timestamped entry to the current log file.

.PARAMETER Message
    Plain-text message to write to the log.

.PARAMETER Level
    Log level for the entry.
#>
function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS', 'DETAIL')]
        [string]$Level = 'INFO'
    )
    if (-not $Global:LogVerbosity) { $Global:LogVerbosity = 'Detailed' }
    if ($Global:LogVerbosity -eq 'None') { return }
    if ($Global:LogVerbosity -eq 'Normal' -and $Level -eq 'DETAIL') { return }
    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $logEntry = "{0} | {1} | {2}" -f $timestamp, $Level, $Message
    if ($logEntry.Length -gt 200) {
        $logEntry = "{0}..." -f $logEntry.Substring(0, 197)
    }
    if ($Global:LogFile) {
        $logEntry | Out-File -FilePath $Global:LogFile -Append -Encoding utf8
    }
}

<#
.SYNOPSIS
    Writes a console status line without logging it.

.PARAMETER Message
    Message to display.

.PARAMETER Symbol
    Prefix symbol displayed before the message.

.PARAMETER Color
    Console color used for the message.
#>
function Write-Status {
    param(
        [string]$Message,
        [string]$Symbol = '*',
        [string]$Color = 'Cyan'
    )
    Write-Host "$Symbol $Message" -ForegroundColor $Color
}

<#
.SYNOPSIS
    Writes an informational console message and logs it.

.PARAMETER Message
    Message to display and log.
#>
function Write-Info {
    param([Parameter(Mandatory=$true)][string]$Message)
    if (-not $Global:ConsoleVerbosity) { $Global:ConsoleVerbosity = 'Detailed' }
    if ($Global:ConsoleVerbosity -ne 'None') { Write-Host $Message -ForegroundColor Cyan }
    Write-Log $Message 'INFO'
}

<#
.SYNOPSIS
    Writes a warning console message and logs it.

.PARAMETER Message
    Message to display and log.
#>
function Write-Warn {
    param([Parameter(Mandatory=$true)][string]$Message)
    if (-not $Global:ConsoleVerbosity) { $Global:ConsoleVerbosity = 'Detailed' }
    if ($Global:ConsoleVerbosity -ne 'None') { Write-Host $Message -ForegroundColor Yellow }
    Write-Log $Message 'WARN'
}

<#
.SYNOPSIS
    Writes an error console message and logs it.

.PARAMETER Message
    Message to display and log.
#>
function Write-ErrorLog {
    param([Parameter(Mandatory=$true)][string]$Message)
    if (-not $Global:ConsoleVerbosity) { $Global:ConsoleVerbosity = 'Detailed' }
    if ($Global:ConsoleVerbosity -ne 'None') { Write-Host $Message -ForegroundColor Red }
    Write-Log $Message 'ERROR'
}

<#
.SYNOPSIS
    Writes a success console message and logs it.

.PARAMETER Message
    Message to display and log.
#>
function Write-Success {
    param([Parameter(Mandatory=$true)][string]$Message)
    if (-not $Global:ConsoleVerbosity) { $Global:ConsoleVerbosity = 'Detailed' }
    if ($Global:ConsoleVerbosity -ne 'None') { Write-Host $Message -ForegroundColor Green }
    Write-Log $Message 'SUCCESS'
}

<#
.SYNOPSIS
    Writes a detailed console message and detailed log entry.

.PARAMETER Message
    Detail message to display and log.
#>
function Write-Detail {
    param([Parameter(Mandatory=$true)][string]$Message)
    if (-not $Global:ConsoleVerbosity) { $Global:ConsoleVerbosity = 'Detailed' }
    if (-not $Global:LogVerbosity) { $Global:LogVerbosity = 'Detailed' }
    
    # Only output detail when verbosity is Detailed
    if ($Global:ConsoleVerbosity -eq 'Detailed') {
        Write-Host ("    [detail] $Message") -ForegroundColor DarkGray
    }
    
    if ($Global:LogVerbosity -eq 'Detailed') {
        Write-Log -Message $Message -Level 'DETAIL'
    }
}

<#
.SYNOPSIS
    Initializes the per-run log file used by calling scripts.

.PARAMETER ScriptName
    Name used in the generated log file name.

.PARAMETER Version
    Version written to the log header when provided.
#>
function Initialize-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ScriptName,
        [Parameter(Mandatory=$false)]
        [string]$Version
    )
    if (-not $Global:LogVerbosity) { $Global:LogVerbosity = 'Detailed' }
    if ($Global:LogVerbosity -eq 'None') { return }
    if (-not $Global:LogFile) {
        $ts = (Get-Date).ToString('yyyyMMdd_HHmmss')
        $defaultLogsDir = Join-Path -Path $PSScriptRoot -ChildPath 'logs'
        $logsDir = $defaultLogsDir

        try {
            if (-not (Test-Path -Path $logsDir -PathType Container)) {
                New-Item -ItemType Directory -Path $logsDir -Force -ErrorAction Stop | Out-Null
            }

            $probeFile = Join-Path -Path $logsDir -ChildPath ('.write-test-{0}.tmp' -f $ts)
            Set-Content -Path $probeFile -Value 'write-test' -Encoding utf8 -ErrorAction Stop
            Remove-Item -Path $probeFile -Force -ErrorAction SilentlyContinue
        } catch {
            $logsDir = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
            Write-Warn ("Logs directory '{0}' is not writable. Falling back to '{1}'." -f $defaultLogsDir, $logsDir)
        }

        try {
            $Global:LogFile = Join-Path -Path $logsDir -ChildPath "${ScriptName}_$ts.log"
            "Log initialized: $Global:LogFile" | Out-File -FilePath $Global:LogFile -Encoding utf8 -ErrorAction Stop
            if ($Version) {
                $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                "$timestamp | INFO | Script: $ScriptName | Version: $Version" | Out-File -FilePath $Global:LogFile -Append -Encoding utf8 -ErrorAction Stop
            }
        } catch {
            $Global:LogFile = $null
            Write-ErrorLog ("Could not initialize log file: {0}" -f $_.Exception.Message)
        }
    }
}

<#
.SYNOPSIS
    Returns the symbol and color for a readiness status.

.PARAMETER Status
    Readiness status to map.

.OUTPUTS
    Hashtable with Symbol and Color keys.
#>
function Get-StatusSymbol {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Status
    )
    
    switch ($Status) {
        'OK'      { return @{ Symbol = '[V]'; Color = 'Green' } }
        'WARNING' { return @{ Symbol = '[!]'; Color = 'Yellow' } }
        'ERROR'   { return @{ Symbol = '[X]'; Color = 'Red' } }
        'UNKNOWN' { return @{ Symbol = '[?]'; Color = 'Gray' } }
        default   { return @{ Symbol = '[-]'; Color = 'Gray' } }
    }
}

<#
.SYNOPSIS
    Displays script or module version information from the manifest.

.PARAMETER ScriptName
    Name of the manifest entry to read.

.PARAMETER ScriptDir
    Directory that contains scripts-manifest.json.
#>
function Get-ScriptVersion {
    param(
        [Parameter(Mandatory=$true)][string]$ScriptName,
        [Parameter(Mandatory=$true)][string]$ScriptDir
    )
    
    $manifestPath = Join-Path -Path $ScriptDir -ChildPath 'scripts-manifest.json'
    
    if (-not (Test-Path -Path $manifestPath)) {
        Write-ErrorLog 'Error: scripts-manifest.json not found'
        return
    }
    
    try {
        $manifest = Get-Content -Path $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json
        $scriptInfo = $manifest.scripts.$ScriptName
        
        if ($scriptInfo) {
            $version = if ($scriptInfo.version) { $scriptInfo.version } elseif ($scriptInfo.moduleVersion) { $scriptInfo.moduleVersion } else { 'Unknown' }
            $description = if ($scriptInfo.description) { $scriptInfo.description } else { 'No description available' }
            $minPS = if ($scriptInfo.minPowerShell) { $scriptInfo.minPowerShell } else { 'Unknown' }
            
            Write-Host "$ScriptName version $version" -ForegroundColor Cyan
            Write-Host "Repository version: $($manifest.repoVersion)" -ForegroundColor Gray
            Write-Host ""
            Write-Host "Description: $description" -ForegroundColor White
            Write-Host "Minimum PowerShell: $minPS" -ForegroundColor Gray
        } else {
            Write-ErrorLog ("Error: Script '{0}' not found in manifest" -f $ScriptName)
        }
    } catch {
        Write-ErrorLog ("Error reading manifest: {0}" -f $_.Exception.Message)
    }
}

<#
.SYNOPSIS
    Sets the active console output encoding to UTF-8.
#>
function Initialize-ConsoleEncoding {
    try {
        # Set console code page to UTF-8 (65001)
        chcp 65001 > $null
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $Global:OutputEncoding = [System.Text.Encoding]::UTF8
    } catch {
        Write-Warn ("Could not set console encoding to UTF-8: {0}" -f $_.Exception.Message)
    }
}

# Export all functions
Export-ModuleMember -Function Write-Log, Write-Status, Write-Info, Write-Warn, Write-ErrorLog, Write-Success, Write-Detail, Initialize-Log, Get-StatusSymbol, Get-ScriptVersion, Initialize-ConsoleEncoding
