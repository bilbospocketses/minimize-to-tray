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
- Shipped as a self-contained Windows .exe via Ahk2Exe; .ahk source also published in the release.
- Vendored build dependencies (AutoHotkey v2.0.26 runtime + Ahk2Exe v1.1.37.02a2 compiler) under `dependencies/` -- repo is fully self-contained, no AutoHotkey install required to build from source.
- `build.ps1` (PowerShell 5.1+) compiles the .exe from source using only the vendored binaries.
