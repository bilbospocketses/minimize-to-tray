<p align="center">
  <img src="assets/app.png" alt="minimize-to-tray" width="160">
</p>

<h1 align="center">minimize-to-tray</h1>

<p align="center">A small Windows utility that adds "minimize to system tray" with smart grouping by app.</p>

<p align="center">
  <img src="https://img.shields.io/badge/status-pre--release-orange" alt="Status: pre-release">
  <img src="https://img.shields.io/badge/platform-Windows%2010%2F11-lightgrey" alt="Platform: Windows 10/11">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License: MIT">
</p>

## Why

Windows doesn't ship with minimize-to-tray. The existing utilities in this space (RBTray, MinTrayR, TrayIt, various AutoHotkey scripts) are stale, fork-fragmented, or behave inconsistently on modern Windows. This is a focused v1 with two triggers, zero configuration, and consistent behavior across modern Win32 apps.

## Install

Two options from the [latest release](https://github.com/bilbospocketses/minimize-to-tray/releases/latest):

- **`minimize-to-tray-win-Setup.exe`** (recommended) — Velopack installer. Per-user install to `%LocalAppData%\minimize-to-tray\`, adds Start Menu + Desktop shortcuts, registers in Add/Remove Programs, and wires up the auto-update path. No UAC prompt.
- **`minimize-to-tray-win-Portable.zip`** — extract anywhere and run `minimize-to-tray.exe`. No install, no shortcuts, no Add/Remove entry. Manual updates only (the blue update-available dot won't apply downloaded packages without the Velopack folder layout the installer creates).

The AutoHotkey runtime is bundled into the executable either way — there's nothing to install separately on the target machine.

**First-run note:** Windows SmartScreen will warn about the unsigned installer/executable. Click **More info** -> **Run anyway**. Code signing is a planned follow-up.

### Updates

When a newer version is published to the [Releases page](https://github.com/bilbospocketses/minimize-to-tray/releases), the app's About dialog (single-left-click the tray icon) shows a pulsing blue dot in the top-right corner. Click the dot to download and apply the update in place — the app restarts on the new version automatically. Update checking happens silently ~5 seconds after launch via the bundled `updater-helper.exe`.

## Usage

Two ways to minimize the current window to the system tray:

- **`Win+Shift+Z`** -- minimize the focused window.
- **Middle-click on a window's title bar** -- minimize that window.

Windows of the same app collapse under a single tray icon (showing the app's own icon):

- **Left-click** a tray icon -> restore the most recently minimized window (LIFO).
- **Right-click** a tray icon -> menu listing every minimized window of that app, plus *Restore All* and *Close All*.

The app's own always-visible tray icon (separate from the per-app ones) shows the shortcuts on hover, and right-clicks to **About** / **Exit**.

When the program exits cleanly, every hidden window is restored automatically.

## Known limitations (v1.0.0)

### Middle-click on title bars: pass-through in apps that consume the click

Modern apps with custom-drawn title bars (Chrome, Edge, Firefox, File Explorer, Office, VS Code, and others with tab strips) only report their actual drag-handle region as a "title bar" to Windows. If you middle-click on something *inside* their UI -- a Chrome/Edge/Firefox tab, an Explorer tab, an Office ribbon -- those apps consume the click for their own behavior (typically closing the tab) before our predicate sees it. Middle-clicking on the **empty drag region** at the top of those windows still works for minimizing.

`Win+Shift+Z` is the universal fallback: it works in every app, every time, regardless of how that app handles middle-click.

### No crash recovery in v1.0.0

If the program crashes hard while windows are hidden, those windows stay hidden until you restart the owning app or end its process via Task Manager. Apps with auto-save (Word, browsers, etc.) survive cleanly. A `--rescue` mode that enumerates hidden top-level windows and offers to restore them is parked for a follow-up release.

### Windows 11 collapsed-tray-icons mode

Per-app tray icons may hide in the overflow flyout. Functionality is identical, but you may want to pin the icons if you prefer them always visible.

### SmartScreen warning on first run

The v1.0.0 .exe is unsigned. SmartScreen surfaces a warning on first run -- click "More info" -> "Run anyway". Code signing planned for a follow-up release.

## Requirements

- Windows 10 or 11 (64-bit).

## Build from source

The repo vendors all build-time binaries under `dependencies/`, so **no AutoHotkey install is required** -- a fresh clone can build the .exe from source.

```powershell
.\build.ps1
```

Output: `dist\minimize-to-tray.exe`.

Requirements:
- Windows PowerShell 5.1+ (ships with Windows 10/11) or PowerShell 7+.
- Nothing else.

See [`dependencies/README.md`](dependencies/README.md) for what's vendored, version pins, and the refresh procedure.

## Project layout

```
minimize-to-tray.ahk    The script (AutoHotkey v2)
build.ps1               Build chain: Ahk2Exe -> dotnet publish -> vpk pack
updater-helper/         .NET 10 Velopack update bridge (CLI: `check`, `update`)
dotnet-tools.json       Project-pinned vpk (Velopack CLI)
assets/                 App icon (.ico, .png) + source materials
dependencies/           Vendored build-time binaries (AHK runtime + Ahk2Exe)
.github/                Dependabot config + CI / Scorecard workflows
docs/specs/             Design specs
docs/plans/             Implementation plans
```

## License

The `minimize-to-tray` source code is licensed under [MIT](LICENSE).

### Third-party attributions

This project is built on top of [AutoHotkey](https://www.autohotkey.com/) ([github.com/AutoHotkey/AutoHotkey](https://github.com/AutoHotkey/AutoHotkey)), licensed under [GPL v2](dependencies/autohotkey/v2.0.26/LICENSE-AutoHotkey.txt). The AutoHotkey runtime is bundled into the compiled `minimize-to-tray.exe` (per Ahk2Exe's standard compilation model), so the executable is a combined work containing GPL-licensed components -- distribution complies with GPL v2 terms.

Build-time compilation uses [Ahk2Exe](https://github.com/AutoHotkey/Ahk2Exe), licensed under [WTFPL v2](dependencies/autohotkey/ahk2exe/v1.1.37.02a2/LICENSE-Ahk2Exe.txt). Ahk2Exe is used only at build time and is not bundled into the output.

The `minimize-to-tray` MIT license applies to the original `minimize-to-tray.ahk` source and any other original code in this repository.
