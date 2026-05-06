# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## UcpdUtils.psm1

### [1.0.0] - 2026-05-06

#### Added

- New shared module exposing `Get-UcpdStatus` and `Set-UcpdState` for use by multiple scripts without child-process invocation.
- `Get-UcpdStatus` returns a structured object with `IsActive`, `DriverPresent`, `ServiceRegistered`, `StartTypeLabel`, `RunningStatus`, and `IsAdmin`.
- `Set-UcpdState` returns a structured object with `Success`, `Reason`, `RequiresReboot`, and `Message`. Never calls `exit`; callers decide how to handle results.

## get-application-associations.ps1

### [3.5.0] - 2026-05-05

#### Added

- Logging support: `LogVerbosity` parameter now writes to a log file via `SharedUtils`.

#### Changed

- Imports `SharedUtils.psd1` (module manifest) instead of relying on local console-output functions.
- Console output now uses `Write-Info`, `Write-Detail`, and `Write-ErrorLog` from `SharedUtils`.
- Console encoding initialized to UTF-8 at startup via `Initialize-ConsoleEncoding`.

### [3.4.0] - 2026-05-04

#### Changed

- CSV export (`-ExportCsv` with `-App` or `-Category`) now uses the version-stripped friendly name in the `Application` column, consistent with what `-ListApps` displays. `MuseScore 3` / `MuseScore 4` are still kept as-is since they cannot be distinguished without the version.

### [3.3.0] - 2026-05-04

#### Changed

- `-ListApps` now strips trailing version numbers (e.g. `GIMP 3.2.4` → `GIMP`, `LibreOffice 26.2` → `LibreOffice`) when the base name is unique. If multiple entries share the same base name (e.g. `MuseScore 3` and `MuseScore 4`), the version is kept to distinguish them.
- `-App` now also accepts the version-stripped name (e.g. `LibreOffice`) as input, matching the name shown by `-ListApps`.

### [3.2.0] - 2026-05-04

#### Changed

- `-ListApps` no longer shows AppX entries that could not be resolved to a friendly name (those whose display name remained the raw `AppXxxxxxxxx` hash). Use `-ListAppsRaw` to see all registered entries including these unresolved ones.

## set-default-applications.ps1

### [2.9.0] - 2026-05-06

#### Added

- UCPD-protected extensions (`.htm`, `.html`, `.pdf`, `.svg`, `.xhtml`, `.shtml`, `.webp`) and protocols (`http`, `https`) are now declared in the configuration section.
- Before processing, if any requested association is UCPD-protected, the script checks UCPD status via `UcpdUtils.psm1` and attempts to disable it automatically (requires admin rights).
- If UCPD cannot be disabled (no admin rights, or reboot required), protected associations are skipped and a clear error is reported at the end with the reason and required next action.
- Imports `UcpdUtils.psm1`.

### [2.8.0] - 2026-05-05

#### Changed

- Imports `SharedUtils.psd1` (module manifest) instead of `SharedUtils.psm1` directly.
- Console encoding initialized to UTF-8 at startup via `Initialize-ConsoleEncoding`.

### [2.4.0] - 2026-05-04

#### Changed

- The `Application` column in CSV files now also accepts version-stripped friendly names (e.g. `LibreOffice` in addition to `LibreOffice 26.2`).

## get-ucpd-status.ps1

### [1.0.1] - 2026-05-06

#### Fixed

- Switched to `SharedUtils.psd1` and initialized console output encoding to UTF-8, matching the existing scripts in this repository.
- Replaced user-facing Unicode dash characters with ASCII-only output to avoid mojibake in legacy console hosts.

### [1.0.0] - 2026-05-06

#### Added

- New read-only diagnostic script to report UCPD driver presence, service registration, configured start type, current running state, and whether the current PowerShell session is elevated.
- Color-coded OK/WARNING/ERROR summary output and per-run logging via `SharedUtils`.

## get-ucpd-status.ps1

### [2.0.0] - 2026-05-06

#### Changed

- Refactored into a thin wrapper around `UcpdUtils.psm1`. All UCPD status logic now lives in the shared module.
- Imports `UcpdUtils.psm1` and calls `Get-UcpdStatus`.

## set-ucpd-service.ps1

### [3.0.0] - 2026-05-06

#### Changed

- Refactored into a thin wrapper around `UcpdUtils.psm1`. All UCPD state-change logic now lives in the shared module.
- Imports `UcpdUtils.psm1` and calls `Set-UcpdState`.
- Removed `-WhatIf` support (was `SupportsShouldProcess`). The underlying `Set-UcpdState` function never calls `exit`, enabling structured result handling by callers.

### [2.0.0] - 2026-05-06

#### Changed

- Renamed the `StartType` parameter to `State` to reflect the script's higher-level purpose: changing the effective UCPD state, not only the service start type.

### [1.0.1] - 2026-05-06

#### Fixed

- Switched to `SharedUtils.psd1` and initialized console output encoding to UTF-8, matching the existing scripts in this repository.
- Replaced user-facing Unicode dash characters with ASCII-only output to avoid mojibake in legacy console hosts.

### [1.0.0] - 2026-05-06

#### Added

- New administrative script to set the UCPD service start type to `Disabled` or restore the Windows default.
- Before/after state reporting, `-WhatIf` support, attempted immediate stop when disabling, and reboot guidance after changes.
