---
applyTo: "**"
---
<!-- AUTO-SYNCED from github.com/Chemin-Neuf/dev-standards DO NOT EDIT HERE — edit in dev-standards and re-sync -->
<!--
  Chemin-Neuf dev-standards — global rules
  Last Updated: 2026-05-03
  Original Author: Claude Sonnet 4.6 (Anthropic / GitHub Copilot)
  This file is AI-generated operational instructions for use by AI coding assistants.
  It is derived from and must remain consistent with PRINCIPLES.md, which is the
  human-authored authoritative source. Do not edit PRINCIPLES.md with AI assistance.
-->

# Global Rules — All Repos and Languages

## License

**STATUS: DECIDED**

- First-party projects are licensed under GNU General Public License v3 only (`GPL-3.0-only`)
- The `LICENSE` file in every repo must contain the full GPLv3 text
- New first-party source files must include the approved language-specific GPL-3.0-only license notice
- Preserve third-party license notices and attribution as required
- If an existing first-party file has a contradictory or unclear license notice, stop and ask before changing it

## Encoding

**STATUS: DECIDED**

- All files use UTF-8 encoding: source code, scripts, logs, documentation
- Prefer ASCII characters when practical to avoid copy-paste and toolchain compatibility issues
- Use non-ASCII characters only when they are required by the content
- No BOM (Byte Order Mark) unless required by a specific tool
- Log files are UTF-8 encoded plain text

## Design Principles

**STATUS: DECIDED**

Apply these principles in all code and documentation:

- **DRY**: Before creating a new function or utility, check if one already exists
- **Single Source of Truth**: Configuration values live in one place; documentation describes, not duplicates
- **Power User Friendly**: Make behavior configurable where the tool type supports it; see language-specific rules for placement conventions
- **Maintainability**: Write for the next person; use clear names and consistent patterns

## AI Attribution

**STATUS: DECIDED**

When AI substantially assists in creating or modifying a file, record attribution in the file header:
- `Original Author: [Model name]` — if AI wrote the initial version
- `Major Contributors: [Model names]` — if AI made significant changes

Applies to: scripts, modules, documentation, configuration files.

## Security Baseline

**STATUS: DECIDED**

### All files (code, scripts, documentation, configuration)

- Never store secrets, passwords, tokens, or private keys in any file tracked by version control
- This includes comments, documentation, and example values
- Files that must contain sensitive data must be excluded via `.gitignore` or equivalent

### Executable code (PowerShell, Bash)

- Credentials must come from environment variables, a secure vault, or an interactive prompt — never hardcoded
- Interactive credential prompts must never echo input back to the screen
- Log files may contain machine names, usernames, IP addresses, and hardware identifiers — acceptable in our controlled IT environment
- Log files must never contain passwords, tokens, or other authentication material
- Scripts that require elevation must detect the need and request it explicitly; document which operations require administrator rights
- Validate all external input before use; strictness scales with the source — config files and environment variables are untrusted until validated, typed CLI parameters from IT team members are lower risk

### Language-specific security rules

See individual language instruction files for specific functions, patterns, and validation techniques.

## Semantic Versioning

**STATUS: DECIDED**

- Use `MAJOR.MINOR.PATCH` versioning for all versioned artifacts
- New projects and files start at `1.0.0`
- Documentation-only changes do not increment the version

### MAJOR version (X.0.0)
Increment when making **incompatible changes**:
- Breaking changes to script behavior, output format, or public API
- Incompatible changes to log schema or output structure
- Removing or renaming parameters, functions, or script names
- Changes that break existing callers or consumers

### MINOR version (0.X.0)
Increment when adding **backward-compatible features**:
- New checks, features, or optional parameters
- New functions or capabilities that do not break existing usage
- Non-breaking improvements to output or logging

### PATCH version (0.0.X)
Increment for **backward-compatible bug fixes**:
- Bug fixes that do not alter behavior for correct usage
- Performance improvements with no external API changes

### Where version numbers live
See language-specific instruction files for the exact location and format.
Exception: HTML documents do not use version numbers; they use a visible "last updated" date instead.

## Git Commit Conventions

**STATUS: TBD**

The existing project uses conventional commit format informally
(`fix(check-tpm): ...`, `feat(check-windows): ...`).
Decide: adopt this formally for all repos?

## CHANGELOG Format

**STATUS: DECIDED**

- Every project that produces versioned releases must maintain a `CHANGELOG.md` at the root of the repository
- Use the Keep a Changelog format (https://keepachangelog.com)
- Sections within a version entry: `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`
- No `[Unreleased]` section: a version entry is created when the version is actually incremented, not before
- Write entries in plain language for the people who use the tool, not for developers
- The CHANGELOG is maintained by the author of the change — human or AI
- Every code change that increments the version must include a CHANGELOG entry in the same commit
- Documentation-only changes do not require a CHANGELOG entry
- Breaking changes must be clearly marked under `Removed` or `Changed`
- The CHANGELOG is not generated automatically from commit messages
- Pure documentation repositories (no versioned releases) do not need a CHANGELOG

## README Minimum Requirements

**STATUS: DECIDED**

- Every repository must have a `README.md` at the root
- Written in English
- Keep content stable — avoid details that go stale (exact version numbers, full parameter references)
- Use the standard template below when creating a new repository

Minimum sections, in this order:
1. **Purpose** — one paragraph: what it does, for whom, why it exists
2. **Structure** — table or list of key files/folders with their purpose
3. **Prerequisites** — what is needed to run it, when prerequisites exist; use ranges not exact versions (e.g. `PowerShell 5.1+`)
4. **Quick Start** — 2–3 lines showing the most common usage, when a quick start is useful
5. **License** — one line pointing to the `LICENSE` file

### Standard README template

```markdown
# [Project Name]

[One-paragraph purpose statement: what it does, for whom, why it exists.]

## Structure

| File/Folder | Purpose |
|---|---|
| ... | ... |

## Prerequisites

Omit this section if not applicable.

- ...

## Quick Start

Omit this section if not applicable.

```powershell
# Most common usage
```

## License

GPL-3.0-only — see [LICENSE](LICENSE).
```

## Working Language

**STATUS: DECIDED**

- Code identifiers (variables, functions, parameters, script names): **English**
- Code comments: **English**
- Documentation (README, instruction files, CHANGELOG): **English**
- Log files and error messages (audience: IT team): **English**
- End-user-facing console output and interactive prompts (audience: end users): **French**
- Add multilingual support for end-user content if the overhead is small