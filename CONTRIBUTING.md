# Contributing to minimize-to-tray

Thanks for your interest. This document covers the essentials for building from source, the code-style bar, and how to land changes.

## Prerequisites

- **Windows 10 or 11 (64-bit)** — Win32 / Shell_NotifyIcon / WinEvent hooks are the runtime surface
- **.NET 10 SDK** (used to build `updater-helper.exe` and to host the project-pinned `vpk` tool). Install from [dotnet.microsoft.com](https://dotnet.microsoft.com/download)
- **PowerShell 5.1+** (ships with Windows) or PowerShell 7+ — used to run `build.ps1`

No AutoHotkey install required — the AHK v2 runtime stub + Ahk2Exe compiler are both vendored under `dependencies/`.

## Setup

```powershell
git clone https://github.com/bilbospocketses/minimize-to-tray.git
cd minimize-to-tray
dotnet tool restore   # pins vpk per dotnet-tools.json
./build.ps1           # produces dist/minimize-to-tray-win-Setup.exe etc.
```

To iterate on the AHK script without rebuilding the .exe each time:

```powershell
& 'C:/Program Files/AutoHotkey/v2/AutoHotkey.exe' .\minimize-to-tray.ahk
# or with the dev flag forcing the update-available dot for UI smoke:
& 'C:/Program Files/AutoHotkey/v2/AutoHotkey.exe' .\minimize-to-tray.ahk /devshowdot
```

## Project Structure

```
minimize-to-tray.ahk        AutoHotkey v2 script (single-file, ~500 lines)
build.ps1                   Build chain: Ahk2Exe -> dotnet publish -> vpk pack
updater-helper/             .NET 10 Velopack update bridge (CLI: `check`, `update`)
assets/                     App icon (.ico, .png) + source materials
dependencies/               Vendored AutoHotkey runtime + Ahk2Exe compiler
docs/specs/                 Design specs
docs/plans/                 Implementation plans
```

## Code Style

- **AHK v2** — embrace Map/Array, prefer `try` over uninitialized-variable hazards, ASCII-only source (em-dashes / smart quotes break some parsers via Win-1252 mangling)
- **C# 14 / .NET 10** features welcome — pattern matching, records, primary constructors, collection expressions
- **PowerShell 5.1 compatible** — `build.ps1` runs on stock Windows 10/11 without pwsh 7+. No `&&` / `||` pipeline chain, no ternary, no null-coalescing
- **No `Console.WriteLine` in the helper** for diagnostic output — stdout is the contract (`check` prints the version string only). Use `Console.Error.WriteLine` for diagnostics

## Commit Messages

Follow conventional-commit-style prefixes: `feat:`, `fix:`, `refactor:`, `docs:`, `style:`, `chore:`, `build:`, `test:`. Keep the subject line short and imperative.

Do not include AI-generated attribution lines in commit messages.

## Pull Requests

- Keep PRs focused on one concern.
- Update `CHANGELOG.md` under `[Unreleased]` for any user-visible change.
- Update `README.md` when behavior the user sees changes.

## Branch Strategy

`main` is the development branch and is **PR-gated**. Direct pushes to main are blocked at the ruleset level; every change goes branch -> PR -> required checks green -> squash-merge.

**Required status checks** (all must be green before merge):
- `build-and-test` — runs `build.ps1` on `windows-latest`
- `Analyze (csharp)` — CodeQL static analysis on `updater-helper/`
- `Analyze (actions)` — CodeQL static analysis on workflow YAML
- `Scorecard analysis` — OpenSSF supply-chain scoring

**Merge method:** Squash only. Rebase is disallowed at the ruleset level (would skip GitHub's web-flow signature on the merge commit, producing an unsigned commit that fails the `required_signatures` rule).

**Signed commits required.** Both regular commits to main and `v*` tags must be signed.

**Workflow file edits:** any change to `.github/workflows/*.yml` must SHA-pin every action with a precise version comment (`# vX.Y.Z`, never bare `# v4`) and use the underlying commit SHA, not the annotated-tag object SHA.

## Reporting Bugs

Open an issue on GitHub with:

- Expected vs actual behavior
- OS version (Windows 10/11) and build
- App version (visible in About dialog)
- Steps to reproduce
- Any console output from `updater-helper.exe` if relevant to an update issue

## Reporting Security Issues

Do **not** file a public issue. See `SECURITY.md` for the private reporting flow.

## License

By contributing you agree your contributions are licensed under the project's MIT license. See `LICENSE`.
