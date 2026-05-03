# pc-set-default-applications

Restores Windows 11 default application associations (file extensions and protocols) after a Microsoft update resets them. Intended for the Chemin-Neuf IT team to run on managed PCs, either manually or via a login script / GPO. Associations can be stored either in one CSV file or in several CSV files referenced by an ordered TXT manifest.

## Structure

| File/Folder | Purpose |
|---|---|
| `set-default-applications.ps1` | Main script — resolves SetUserFTA and applies all associations |
| `default-applications.csv` | Configuration: one row per extension or protocol with its target application name |
| `default-applications.txt` | Sample ordered manifest listing one or more CSV configuration files |
| `get-application-associations.ps1` | Discovery tool — queries the registry to find app names, categories, and ProgIDs |
| `SharedUtils.psm1` | Shared logging utilities (synced from ps-shared-utils) |
| `logs\` | Per-run log files (created automatically next to the script, or in %TEMP% as fallback) |

## Prerequisites

- PowerShell 5.1+
- Network access to `setuserfta.com` **or** access to `\\your-server\your-share\SetUserFTA.exe`
- No administrator rights required

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

Edit `default-applications.csv` to add your associations. Each uncommented row maps one file extension (`.pdf`) or protocol (`http`) to a registered application name such as `Windows Photo Viewer` or `VLC media player`. Spaces in names are fine; only quote a value if it contains a comma. If you want to split the configuration into several CSV files, list them in `default-applications.txt` in the exact order they should be applied; later files win when the same association appears more than once.

## License

GPL-3.0-only — see [LICENSE](LICENSE).
