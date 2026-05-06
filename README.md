# pc-set-default-applications

Restores Windows 11 default application associations (file extensions and protocols) after a Microsoft update resets them. Intended for power users, to run either manually or via a login script / GPO. Associations can be stored either in one CSV file or in several CSV files referenced by an ordered TXT manifest.

## Structure

| File/Folder | Purpose |
|---|---|
| `set-default-applications.ps1` | Main script — resolves SetUserFTA and applies all associations |
| `get-application-associations.ps1` | Discovery tool — queries the registry to find app names, categories, and ProgIDs |
| `get-ucpd-status.ps1` | Read-only diagnostic — reports current UCPD driver and service state |
| `set-ucpd-service.ps1` | Administrative tool — disables or restores the UCPD service start type |
| `ApplicationRegistry.psm1` | Internal module — registry discovery, capabilities resolution, and friendly name derivation |
| `UcpdUtils.psm1` | Internal module — `Get-UcpdStatus` and `Set-UcpdState` shared by the UCPD scripts |
| `SharedUtils.psm1` | Shared logging and console utilities (synced from ps-shared-utils) |
| `SharedUtils.psd1` | PowerShell module manifest for SharedUtils |
| `default-applications.csv` | Configuration: one row per extension or protocol with its target application name |
| `default-applications.txt` | Sample ordered manifest listing one or more CSV configuration files |
| `logs\` | Per-run log files (created automatically next to the script, or in %TEMP% as fallback) |

## Prerequisites

- PowerShell 5.1+
- Network access to `setuserfta.com` **or** access to `\\your-server\your-share\SetUserFTA.exe`
- No administrator rights required (except `set-ucpd-service.ps1`)

## Quick Start

```powershell
# Run with the default configuration file
.\set-default-applications.ps1

# Run with a custom configuration file
.\set-default-applications.ps1 -ConfigPath "C:\IT\my-defaults.csv"

# Run with an ordered TXT manifest listing multiple CSV files
.\set-default-applications.ps1 -ConfigType TXT -ConfigPath ".\default-applications.txt"

# Show full console output
.\set-default-applications.ps1 -Verbosity Detailed
```

Edit `default-applications.csv` to add your associations. Each uncommented row maps one file extension (`.pdf`) or protocol (`http`) to a registered application name such as `Windows Photo Viewer` or `VLC media player`. Spaces in names are fine; only quote a value if it contains a comma. If you want to split the configuration into several CSV files, list them in `default-applications.txt` in the exact order they should be applied; later files win when the same association appears more than once. In a TXT manifest, relative CSV paths are resolved from the manifest file's directory, while absolute paths are kept as-is.

`get-application-associations.ps1 -ListApps` groups registered applications by a friendly display name resolved from Windows metadata, so entries such as `Brave.R6XA3SEV5DUAGVO75MIQPSAUGE` appear as `Brave`, and related registrations such as `CDBurnerXP.axp`, `CDBurnerXP.dxp`, and `CDBurnerXP.iso` are grouped under `CDBurnerXP`. `get-application-associations.ps1 -ListAppsRaw` shows the raw names stored in `RegisteredApplications` for compatibility. The old `-ListAppsFriendly` switch still works as an alias for `-ListApps`.

`get-application-associations.ps1 -App <name>` and `-Category <type>` output detailed association objects and can export them directly to a CSV with `-ExportCsv`. `-ListCategories` lists all perceived-type category names (such as `video`, `audio`) that exist on the current machine.

`get-ucpd-status.ps1` checks whether the UCPD (UserChoice Protection Driver) is present, registered, and running — this driver can block SetUserFTA from writing UserChoice keys. No changes are made; the output includes color-coded OK / WARNING / ERROR indicators. Run this first if associations are not being applied.

`set-ucpd-service.ps1 -State Disabled` configures the UCPD service start type to Disabled and attempts to stop the running driver immediately; `-State Default` restores the Windows default (Automatic). Administrator rights are required. A reboot is normally needed for any change to take full effect.

## Built-in Help

Every script in this toolset includes full PowerShell comment-based help. Use `Get-Help` to read it without leaving the terminal:

```powershell
# Synopsis and syntax overview
Get-Help .\set-default-applications.ps1

# Full help including all parameters and examples
Get-Help .\set-default-applications.ps1 -Full

# Parameters only
Get-Help .\set-default-applications.ps1 -Parameter *

# Examples only
Get-Help .\set-default-applications.ps1 -Examples
```

Replace the script name with any other script in the toolset (`get-application-associations.ps1`, `get-ucpd-status.ps1`, `set-ucpd-service.ps1`) to read its help.

## License

GPL-3.0-only — see [LICENSE](LICENSE).
