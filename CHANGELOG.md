# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## get-application-associations.ps1

### [3.3.0] - 2026-05-04

#### Changed

- `-ListApps` now strips trailing version numbers (e.g. `GIMP 3.2.4` → `GIMP`, `LibreOffice 26.2` → `LibreOffice`) when the base name is unique. If multiple entries share the same base name (e.g. `MuseScore 3` and `MuseScore 4`), the version is kept to distinguish them.
- `-App` now also accepts the version-stripped name (e.g. `LibreOffice`) as input, matching the name shown by `-ListApps`.

### [3.2.0] - 2026-05-04

#### Changed

- `-ListApps` no longer shows AppX entries that could not be resolved to a friendly name (those whose display name remained the raw `AppXxxxxxxxx` hash). Use `-ListAppsRaw` to see all registered entries including these unresolved ones.

## set-default-applications.ps1

### [2.4.0] - 2026-05-04

#### Changed

- The `Application` column in CSV files now also accepts version-stripped friendly names (e.g. `LibreOffice` in addition to `LibreOffice 26.2`).
