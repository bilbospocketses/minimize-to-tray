# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-05-23

### Added
- Initial release. Minimize the focused window to the system tray via `Win+Shift+Z` or middle-click on a title bar.
- Group minimized windows by process executable name; one tray icon per group with the app's own icon.
- Left-click a per-group tray icon to restore the most recently minimized window (LIFO).
- Right-click a per-group tray icon for a per-window picker plus Restore All / Close All.
- Always-visible app tray icon. Single left-click opens About; right-click opens a menu with **About** / **Run on login** (checkmark reflects state) / **Exit**.
- **Run on login** toggle (writes to `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`). Surfaced both in the About dialog (centered checkbox) and the tray right-click menu, kept in sync.
- About dialog: custom Gui with embedded app icon, version, shortcut reminders, a top-right pulsing blue update-available dot (click to download + apply via Velopack), and a clickable GitHub URL.
- Event-driven cleanup of tray icons when tracked windows die externally (`SetWinEventHook(EVENT_OBJECT_DESTROY)`).
- On exit, every hidden window is restored automatically.
- Shipped via Velopack: `minimize-to-tray-win-Setup.exe` installer + `minimize-to-tray-win-Portable.zip` portable archive. AutoHotkey runtime bundled into the executable; no AutoHotkey install required on the target machine.
- Velopack-managed in-place update flow via a small `updater-helper.exe` (.NET 10, Velopack.Sdk.UpdateManager, GitHub Releases feed source).
- Vendored build dependencies (AutoHotkey v2.0.26 runtime + Ahk2Exe v1.1.37.02a2 compiler) under `dependencies/`; vpk (Velopack CLI) pinned to 0.0.1589-ga2c5a97 via `dotnet-tools.json`. Repo is fully self-contained -- a fresh clone can build from source with only .NET 10 SDK + PowerShell installed.
- `build.ps1` (PowerShell 5.1+) chains Ahk2Exe -> `dotnet publish` updater-helper -> `vpk pack` -> Setup.exe + Portable.zip + .nupkg + RELEASES feed.

### Security
- Repo hardened to CM-parity security baseline per the lockdown protocol: Dependabot alerts + automated security updates + secret scanning + push protection + Private Vulnerability Reporting all enabled. Actions allowlist active with `sha_pinning_required: true`. Squash-only merge policy. Branch ruleset on `main`: required signatures + linear history + PR-only changes + required status checks (`build-and-test` + `Scorecard analysis`). Tag ruleset on `refs/tags/v*`: required signatures + non-fast-forward + no deletion.
- All workflow actions SHA-pinned to commit objects with precise `# vX.Y.Z` comments per the OpenSSF Scorecard imposter-commit verifier + Dependabot version-tracking lessons.

[Unreleased]: https://github.com/bilbospocketses/minimize-to-tray/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/bilbospocketses/minimize-to-tray/releases/tag/v1.0.0
