# Copyright (C) Chemin-Neuf IT Team
# SPDX-License-Identifier: GPL-3.0-only
# Full license text: see LICENSE at the repository root
# Original Author: Claude Sonnet 4.6 (GitHub Copilot)
<#
.SYNOPSIS
    Shared registry-discovery functions for the pc-set-default-applications toolset.

.DESCRIPTION
    Provides all Windows RegisteredApplications registry access, capabilities-key
    resolution, friendly display-name derivation, and per-session caches.
    Consumed by get-application-associations.ps1 and set-default-applications.ps1.
#>

# ============================================================
# MODULE-LEVEL CACHES
# ============================================================
$script:registeredApplicationsCache        = $null
$script:resolvedRegisteredApplicationsCache = @{}
$script:indirectStringCache                = @{}

# ============================================================
# LOW-LEVEL REGISTRY HELPERS
# ============================================================

<#
.SYNOPSIS
    Opens a registry subkey using the .NET registry API.

.DESCRIPTION
    Uses Microsoft.Win32.RegistryKey directly instead of the PowerShell registry
    provider. This is roughly 1000x faster for bulk operations and correctly
    handles the Software\Classes\Local Settings\ path used by AppX packages,
    which the PS provider cannot open.

.PARAMETER Hive
    Registry hive: HKCU or HKLM.

.PARAMETER View
    Registry view: Registry64 or Registry32.

.PARAMETER SubKeyPath
    Registry path below the hive root (no leading backslash).

.OUTPUTS
    An open Microsoft.Win32.RegistryKey, or $null if the key does not exist.
    The caller is responsible for calling Dispose() on the returned key.
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

<#
.SYNOPSIS
    Returns an ordered hashtable of all named value names and data from a registry key.

.PARAMETER KeyPath
    Full PowerShell-style registry path (e.g. HKLM:\SOFTWARE\...).
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
# CAPABILITIES-KEY RESOLUTION
# ============================================================

<#
.SYNOPSIS
    Builds the list of candidate registry keys to try as a Capabilities key for
    one registered application.

.DESCRIPTION
    RegisteredApplications values may be relative paths (Software\...), fully
    qualified Win32 paths (HKEY_LOCAL_MACHINE\...), or PS-style paths (HKLM:\...).
    32-bit apps on 64-bit Windows may be stored under WOW6432Node. This function
    normalises all forms and returns all plausible locations to check in order.

.PARAMETER RawPath
    Raw value stored under RegisteredApplications.

.PARAMETER Hive
    The hive (HKCU or HKLM) from which this registration was read. Used to
    determine the preferred search order for relative paths.

.PARAMETER View
    The registry view (Registry64 or Registry32) from which this registration
    was read.

.OUTPUTS
    An array of PSCustomObjects with Hive, View, SubKeyPath, and PowerShellPath.
#>
function Get-CapabilitiesKeyCandidates {
    param(
        [Parameter(Mandatory=$true)][string]$RawPath,
        [Parameter(Mandatory=$true)][string]$Hive,
        [Parameter(Mandatory=$true)][string]$View
    )

    $candidates    = [System.Collections.Generic.List[PSObject]]::new()
    $seenKeys      = @{}

    function Add-Candidate {
        param(
            [Parameter(Mandatory=$true)][string]$CandidateHive,
            [Parameter(Mandatory=$true)][string]$CandidateView,
            [Parameter(Mandatory=$true)][string]$CandidateSubKeyPath,
            [Parameter(Mandatory=$true)][string]$CandidatePowerShellPath
        )
        $key = '{0}|{1}|{2}' -f $CandidateHive, $CandidateView, $CandidateSubKeyPath
        if ($seenKeys.ContainsKey($key)) { return }
        $candidates.Add([PSCustomObject]@{
            Hive           = $CandidateHive
            View           = $CandidateView
            SubKeyPath     = $CandidateSubKeyPath
            PowerShellPath = $CandidatePowerShellPath
        })
        $seenKeys[$key] = $true
    }

    # Fully-qualified Win32 paths: HKEY_LOCAL_MACHINE\... or HKEY_CURRENT_USER\...
    if ($RawPath -match '^HKEY_LOCAL_MACHINE\\(.+)$') {
        $sub = $Matches[1]
        if ($sub -match '^SOFTWARE\\WOW6432Node\\(.+)$') {
            Add-Candidate 'HKLM' 'Registry32' ('SOFTWARE\{0}' -f $Matches[1]) ('HKLM:\SOFTWARE\WOW6432Node\{0}' -f $Matches[1])
        } else {
            Add-Candidate 'HKLM' 'Registry64' $sub ('HKLM:\{0}' -f $sub)
        }
        return @($candidates)
    }
    if ($RawPath -match '^HKEY_CURRENT_USER\\(.+)$') {
        $sub = $Matches[1]
        if ($sub -match '^SOFTWARE\\WOW6432Node\\(.+)$') {
            Add-Candidate 'HKCU' 'Registry32' ('SOFTWARE\{0}' -f $Matches[1]) ('HKCU:\SOFTWARE\WOW6432Node\{0}' -f $Matches[1])
        } else {
            Add-Candidate 'HKCU' 'Registry64' $sub ('HKCU:\{0}' -f $sub)
        }
        return @($candidates)
    }

    # PS-style drive prefixes: normalise to Win32 and recurse once.
    if ($RawPath -match '^HKLM:\\(.+)$') {
        return Get-CapabilitiesKeyCandidates -RawPath ('HKEY_LOCAL_MACHINE\{0}' -f $Matches[1]) -Hive $Hive -View $View
    }
    if ($RawPath -match '^HKCU:\\(.+)$') {
        return Get-CapabilitiesKeyCandidates -RawPath ('HKEY_CURRENT_USER\{0}' -f $Matches[1]) -Hive $Hive -View $View
    }

    # Relative Software\... paths: prefer the hive that declared the registration, then
    # try the alternate hive. Also include the WOW6432Node variant for 32-bit apps.
    if ($RawPath -match '^Software\\(.+)$') {
        $rel = $Matches[1]
        if ($View -eq 'Registry32') {
            Add-Candidate $Hive 'Registry32' ('SOFTWARE\{0}' -f $rel) ('{0}:\SOFTWARE\WOW6432Node\{1}' -f $Hive, $rel)
            Add-Candidate $Hive 'Registry64' ('SOFTWARE\{0}' -f $rel) ('{0}:\SOFTWARE\{1}'            -f $Hive, $rel)
        } else {
            Add-Candidate $Hive 'Registry64' ('SOFTWARE\{0}' -f $rel) ('{0}:\SOFTWARE\{1}'            -f $Hive, $rel)
            Add-Candidate $Hive 'Registry32' ('SOFTWARE\{0}' -f $rel) ('{0}:\SOFTWARE\WOW6432Node\{1}' -f $Hive, $rel)
        }
        return @($candidates)
    }

    # Unknown form — try as-is with the originating hive and view.
    Add-Candidate $Hive $View $RawPath ('{0}:\{1}' -f $Hive, $RawPath)
    return @($candidates)
}

# ============================================================
# DISPLAY-NAME RESOLUTION
# ============================================================

<#
.SYNOPSIS
    Resolves an indirect Windows resource string to plain text when possible.

.DESCRIPTION
    Passes the value to SHLoadIndirectString (shlwapi.dll). Plain strings are
    returned unchanged (the API is a no-op for them). DLL resource references
    (@C:\...\file.dll,-id) are resolved. UWP ms-resource:// strings are resolved
    only when the package is active in the current session.
    Results are cached per session to avoid repeated API calls.

.PARAMETER Value
    Raw string value, possibly starting with @ to indicate an indirect reference.
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

    $buffer  = New-Object System.Text.StringBuilder 1024
    $hResult = [RegisteredApplicationNativeMethods]::SHLoadIndirectString($Value, $buffer, $buffer.Capacity, [IntPtr]::Zero)
    if ($hResult -eq 0 -and $buffer.Length -gt 0) {
        $resolved = $buffer.ToString()
        $script:indirectStringCache[$Value] = $resolved
        return $resolved
    }

    $script:indirectStringCache[$Value] = $Value
    return $Value
}

<#
.SYNOPSIS
    Derives a readable label from an unresolved UWP ms-resource indirect string
    by splitting the package name's CamelCase leaf segment into words.

.DESCRIPTION
    Used as a fallback when SHLoadIndirectString cannot resolve the UWP resource
    string (e.g. the package is registered for a different user or the resource
    index is not accessible).
    Example: "@{Microsoft.BingWeather_4.54...?ms-resource://...}" -> "Bing Weather"

.PARAMETER ResourceString
    Raw indirect resource string in @{PackageName_Version?ms-resource://...} form.
#>
function Convert-AppxResourceStringToDisplayName {
    param([AllowNull()][string]$ResourceString)

    if ([string]::IsNullOrWhiteSpace($ResourceString)) { return '' }

    # Only handles UWP-style indirect strings: @{PackageName_Version?ms-resource://...}
    if ($ResourceString -notmatch '^@\{([^_\?]+)') { return '' }

    # The last dot-segment of the package name is the most specific part.
    # e.g. "Microsoft.BingWeather" -> leafName = "BingWeather"
    $packageName = $Matches[1]
    $leafName    = ($packageName -split '\.')[-1]

    # Split CamelCase into words at case transitions.
    # Must use -creplace (case-sensitive); plain -replace is case-insensitive and
    # would insert a space between every pair of letters.
    # Pass 1: lowercase/digit -> uppercase:  "BingWeather" -> "Bing Weather"
    $friendlyName = $leafName -creplace '([a-z0-9])([A-Z])', '$1 $2'
    # Pass 2: uppercase -> uppercase+lowercase: "XMLParser" -> "XML Parser"
    $friendlyName = $friendlyName -creplace '([A-Z])([A-Z][a-z])', '$1 $2'
    return $friendlyName.Trim()
}

<#
.SYNOPSIS
    Resolves the human-readable display name for a registered application using
    a five-step fallback chain.

.DESCRIPTION
    Step 1 — ApplicationName via SHLoadIndirectString.
        Most Win32 apps store a plain string ("Brave"). Office-style apps store a
        DLL resource reference ("@C:\...\oregres.dll,-206"). Both are handled by
        SHLoadIndirectString; plain strings are returned as-is.

    Step 2 — UWP ms-resource string that SHLoadIndirectString could not resolve.
        UWP apps store "@{Microsoft.BingWeather_4.54...?ms-resource://...}".
        When the API fails, the package name's CamelCase leaf is split into words:
        "BingWeather" -> "Bing Weather".

    Step 3 — Office-style registered name ("<Name>.Application.<N>").
        e.g. "Excel.Application.16" -> "Excel"

    Step 4 — Browser/app registered name with a trailing hex suffix ("<Name>-<HEX>").
        e.g. "Firefox-308046B0AF4A39CB" -> "Firefox"

    Step 5 — AppX registration with no resolvable ApplicationName.
        Extracts and CamelCase-splits the last path segment of the capabilities key:
        "...\WebExperienceHost\Capabilities" -> "Web Experience Host"

    If none of the above yields a result, the raw registered name is returned.

.PARAMETER RegisteredName
    Raw application name stored under RegisteredApplications.

.PARAMETER ApplicationName
    Value of the ApplicationName registry entry under the Capabilities key,
    or $null / empty string if the key was not found.

.PARAMETER CapabilitiesRawPath
    Raw capabilities path as stored in RegisteredApplications. Used in Step 5
    to extract the component name from AppX package paths.
#>
function Get-RegisteredApplicationDisplayName {
    param(
        [Parameter(Mandatory=$true)][string]$RegisteredName,
        [AllowNull()][string]$ApplicationName,
        [AllowNull()][string]$CapabilitiesRawPath
    )

    # No Capabilities key found at all — raw name is the only information available.
    if (-not $ApplicationName) { return $RegisteredName }

    # Step 1 — plain string or DLL resource reference resolved via SHLoadIndirectString.
    $resolvedName = Resolve-IndirectString -Value $ApplicationName
    if (-not [string]::IsNullOrWhiteSpace($resolvedName) -and -not $resolvedName.StartsWith('@')) {
        return $resolvedName
    }

    # Step 2 — UWP ms-resource string: split CamelCase package name leaf.
    $appxName = Convert-AppxResourceStringToDisplayName -ResourceString $ApplicationName
    if (-not [string]::IsNullOrWhiteSpace($appxName)) {
        return $appxName
    }

    # Step 3 — Office-style: "Excel.Application.16" -> "Excel"
    if ($RegisteredName -match '^([^.]+)\.Application\.\d+$') {
        return $Matches[1]
    }

    # Step 4 — Hex-suffix: "Firefox-308046B0AF4A39CB" -> "Firefox"
    if ($RegisteredName -match '^(.+?)-[A-F0-9]{8,}$') {
        return $Matches[1]
    }

    # Step 5 — AppX with unresolvable ApplicationName: use capabilities path leaf.
    if ($RegisteredName -like 'AppX*' -and $CapabilitiesRawPath -match '\\([^\\]+)\\Capabilities$') {
        $leafName = ($Matches[1] -split '\.')[-1]
        $leafName = $leafName -creplace '([a-z0-9])([A-Z])', '$1 $2'
        $leafName = $leafName -creplace '([A-Z])([A-Z][a-z])', '$1 $2'
        if (-not [string]::IsNullOrWhiteSpace($leafName) -and $leafName -ne 'App') {
            return $leafName.Trim()
        }
    }

    # No conversion succeeded — return the raw registered name unchanged.
    return $RegisteredName
}

# ============================================================
# REGISTERED APPLICATIONS ENUMERATION
# ============================================================

<#
.SYNOPSIS
    Returns all RegisteredApplications entries visible to the current user as a
    lightweight ordered hashtable (raw data only, no name resolution).

.DESCRIPTION
    Reads from four locations in priority order so that per-user registrations
    shadow machine-wide ones when both declare the same name:
      1. HKCU 64-bit view
      2. HKCU 32-bit view  (WOW6432Node)
      3. HKLM 64-bit view
      4. HKLM 32-bit view  (WOW6432Node)

    Uses the .NET RegistryKey API directly for speed (the PowerShell registry
    provider is ~1000x slower for bulk enumeration).

    Results are cached for the lifetime of the module import so that multiple
    callers in the same script run share one registry read.

.OUTPUTS
    Ordered hashtable keyed by registered application name. Each value is a
    PSCustomObject with RegisteredName, Hive, View, and CapabilitiesRawPath.
#>
function Get-RegisteredApplications {
    if ($script:registeredApplicationsCache) {
        return $script:registeredApplicationsCache
    }

    $result = [ordered]@{}
    $locations = @(
        [PSCustomObject]@{ Hive = 'HKCU'; View = 'Registry64'; SubKeyPath = 'SOFTWARE\RegisteredApplications' },
        [PSCustomObject]@{ Hive = 'HKCU'; View = 'Registry32'; SubKeyPath = 'SOFTWARE\RegisteredApplications' },
        [PSCustomObject]@{ Hive = 'HKLM'; View = 'Registry64'; SubKeyPath = 'SOFTWARE\RegisteredApplications' },
        [PSCustomObject]@{ Hive = 'HKLM'; View = 'Registry32'; SubKeyPath = 'SOFTWARE\RegisteredApplications' }
    )

    foreach ($loc in $locations) {
        $key = Open-RegistrySubKey -Hive $loc.Hive -View $loc.View -SubKeyPath $loc.SubKeyPath
        if (-not $key) { continue }
        try {
            foreach ($appName in ($key.GetValueNames() | Where-Object { $_ } | Sort-Object)) {
                if ($result.Contains($appName)) { continue }   # user-scope wins
                $result[$appName] = [PSCustomObject]@{
                    RegisteredName      = $appName
                    Hive                = $loc.Hive
                    View                = $loc.View
                    CapabilitiesRawPath = [string]$key.GetValue($appName)
                }
            }
        }
        finally {
            $key.Dispose()
        }
    }

    $script:registeredApplicationsCache = $result
    return $result
}

<#
.SYNOPSIS
    Resolves display metadata (friendly name, capabilities path) for one raw
    registered application entry.

.DESCRIPTION
    Reads the ApplicationName value from the first reachable Capabilities key
    candidate, then passes it through Get-RegisteredApplicationDisplayName.
    Results are cached so each registration is resolved at most once per session.

.PARAMETER RegisteredApplication
    A raw entry as returned by Get-RegisteredApplications.

.OUTPUTS
    PSCustomObject with RegisteredName, DisplayName, Hive, View,
    CapabilitiesRawPath, and CapabilitiesPath.
#>
function Resolve-RegisteredApplication {
    param([Parameter(Mandatory=$true)]$RegisteredApplication)

    if ($script:resolvedRegisteredApplicationsCache.ContainsKey($RegisteredApplication.RegisteredName)) {
        return $script:resolvedRegisteredApplicationsCache[$RegisteredApplication.RegisteredName]
    }

    $capabilitiesPath = $null
    $applicationName  = $null

    if ($RegisteredApplication.CapabilitiesRawPath) {
        foreach ($candidate in (Get-CapabilitiesKeyCandidates `
                -RawPath $RegisteredApplication.CapabilitiesRawPath `
                -Hive    $RegisteredApplication.Hive `
                -View    $RegisteredApplication.View)) {
            $capKey = Open-RegistrySubKey -Hive $candidate.Hive -View $candidate.View -SubKeyPath $candidate.SubKeyPath
            if (-not $capKey) { continue }
            try {
                $capabilitiesPath = $candidate.PowerShellPath
                $applicationName  = [string]$capKey.GetValue('ApplicationName')
                break
            }
            finally {
                $capKey.Dispose()
            }
        }
    }

    $resolved = [PSCustomObject]@{
        RegisteredName      = $RegisteredApplication.RegisteredName
        DisplayName         = Get-RegisteredApplicationDisplayName `
                                  -RegisteredName      $RegisteredApplication.RegisteredName `
                                  -ApplicationName     $applicationName `
                                  -CapabilitiesRawPath $RegisteredApplication.CapabilitiesRawPath
        Hive                = $RegisteredApplication.Hive
        View                = $RegisteredApplication.View
        CapabilitiesRawPath = $RegisteredApplication.CapabilitiesRawPath
        CapabilitiesPath    = $capabilitiesPath
    }

    $script:resolvedRegisteredApplicationsCache[$RegisteredApplication.RegisteredName] = $resolved
    return $resolved
}

# ============================================================
# MODULE EXPORTS
# ============================================================
Export-ModuleMember -Function @(
    'Open-RegistrySubKey',
    'Get-RegistryValues',
    'Get-CapabilitiesKeyCandidates',
    'Resolve-IndirectString',
    'Convert-AppxResourceStringToDisplayName',
    'Get-RegisteredApplicationDisplayName',
    'Get-RegisteredApplications',
    'Resolve-RegisteredApplication'
)
