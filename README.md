# pc-set-default-applications

Restores Windows 11 default application associations (file extensions and protocols) after a Microsoft update resets them. Intended for the Chemin-Neuf IT team to run on managed PCs, either manually or via a login script / GPO. The list of associations is kept in a separate CSV file so it can be updated without touching the script.

## Structure

| File/Folder | Purpose |
|---|---|
| `set-default-applications.ps1` | Main script — resolves SetUserFTA and applies all associations |
| `default-applications.csv` | Configuration: one row per extension or protocol with its target ProgID |
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

# Show full console output
.\set-default-applications.ps1 -Verbosity Detailed
```

Edit `default-applications.csv` to add your associations. Each uncommented row maps one file extension (`.pdf`) or protocol (`http`) to a ProgID. See the comments in the file for instructions on finding the correct ProgID for any application.

## License

GPL-3.0-only — see [LICENSE](LICENSE).
