# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

## set-ucpd-service.ps1

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
