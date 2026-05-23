# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial implementation: minimize the focused window to the system tray via `Win+Shift+Z` or middle-click on a title bar.
- Group minimized windows by process executable name; one tray icon per group with the app's own icon.
- Left-click a per-group tray icon to restore the most recently minimized window (LIFO).
- Right-click a per-group tray icon for a per-window picker plus Restore All / Close All.
- Always-visible app tray icon with hover-tooltip reminder of the shortcuts and a Right-click -> Exit option.
- Event-driven cleanup of tray icons when tracked windows die externally.
- On exit, every hidden window is restored.
- Shipped via Velopack: `minimize-to-tray-win-Setup.exe` installer + `minimize-to-tray-win-Portable.zip` portable archive published in the release. AutoHotkey runtime bundled into the executable; no AutoHotkey install required on the target machine.
- Velopack-managed in-place update flow via a small `updater-helper.exe` (.NET 10, Velopack.Sdk.UpdateManager, GitHub Releases feed source).
- Vendored build dependencies (AutoHotkey v2.0.26 runtime + Ahk2Exe v1.1.37.02a2 compiler) under `dependencies/`; vpk (Velopack CLI) pinned to 0.0.1589-ga2c5a97 via `dotnet-tools.json`. Repo is fully self-contained — a fresh clone can build from source with only .NET 10 SDK + PowerShell installed.
- `build.ps1` (PowerShell 5.1+) chains Ahk2Exe -> `dotnet publish` updater-helper -> `vpk pack` -> Setup.exe + Portable.zip + .nupkg + RELEASES feed.
