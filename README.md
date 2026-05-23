<p align="center">
  <img src="assets/app.png" alt="minimize-to-tray" width="160">
</p>

<h1 align="center">minimize-to-tray</h1>

<p align="center">A small Windows utility that adds "minimize to system tray" with smart grouping by app.</p>

<p align="center">
  <img src="https://img.shields.io/github/v/release/bilbospocketses/minimize-to-tray?label=release&color=blue" alt="Latest release">
  <img src="https://img.shields.io/badge/platform-Windows%2010%2F11-lightgrey" alt="Platform: Windows 10/11">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License: MIT">
</p>

## Why

Windows doesn't ship with minimize-to-tray. The existing utilities in this space (RBTray, MinTrayR, TrayIt, various AutoHotkey scripts) are stale, fork-fragmented, or behave inconsistently on modern Windows. This is a focused minimal-surface utility — two triggers, smart per-app grouping, and consistent behavior across modern Win32 apps.

## Install

Two options from the [latest release](https://github.com/bilbospocketses/minimize-to-tray/releases/latest):

- **`minimize-to-tray-win-Setup.exe`** (recommended) — Velopack installer. Per-user install to `%LocalAppData%\minimize-to-tray\`, adds Start Menu + Desktop shortcuts, registers in Add/Remove Programs, and wires up the in-app auto-update path. No UAC prompt. On first install the About dialog pops once so you can opt out of the **Run on login** default (which is ON for fresh installs).
- **`minimize-to-tray-win-Portable.zip`** — extract anywhere and run `minimize-to-tray.exe`. No install, no shortcuts, no Add/Remove entry. Manual updates only (the in-app update flow needs the Velopack folder layout the installer creates).

The AutoHotkey runtime is bundled into the executable either way — there's nothing to install separately on the target machine.

**First-run note:** Windows SmartScreen will warn about the unsigned installer/executable. Click **More info** -> **Run anyway**. Code signing is a planned follow-up.

### Updates

When a newer version is published to the [Releases page](https://github.com/bilbospocketses/minimize-to-tray/releases), the app's About dialog shows a pulsing blue dot to the left of the theme toggle in the top-right corner. Click the dot to download and apply the update in place — the app restarts on the new version automatically.

The update check fires twice: ~5 seconds after each launch, and whenever you open the About dialog. If a check happens to find an update while About is currently open, the dot pops in live — no need to close and reopen.

## Usage

Two ways to minimize the current window to the system tray:

- **`Win+Shift+Z`** — minimize the focused window.
- **Middle-click on a window's title bar** — minimize that window.

Windows of the same app collapse under a single tray icon (showing the app's own icon):

- **Left-click** the per-app tray icon → restore the most recently minimized window (LIFO).
- **Right-click** the per-app tray icon → menu listing every minimized window of that app, plus *Restore All* and *Close All*.

The app's own always-visible tray icon (separate from the per-app ones) has its own behaviors:

- **Hover** → tooltip showing the triggers.
- **Single left-click** → opens **About**.
- **Right-click** → menu with **About** / **Run on login** (toggle, checkmark reflects current state) / **Exit**.

When the program exits cleanly, every hidden window is restored automatically.

### About dialog

The About dialog contains:

- App icon + name + version.
- Trigger reminder.
- **Run on login** checkbox (mirrors the tray menu's toggle).
- Clickable GitHub URL.
- **Light / Dark theme toggle** (☀ / 🌙 glyph) in the top-right corner. Click to flip — dialog body and OS title bar re-style live without reopen. Fresh installs default to your current Windows Apps theme.
- Pulsing blue update dot to the left of the theme toggle when a newer version is available.

## Known limitations

### Middle-click on title bars: pass-through in apps that consume the click

Modern apps with custom-drawn title bars (Chrome, Edge, Firefox, File Explorer, Office, VS Code, and others with tab strips) only report their actual drag-handle region as a "title bar" to Windows. If you middle-click on something *inside* their UI — a Chrome/Edge/Firefox tab, an Explorer tab, an Office ribbon — those apps consume the click for their own behavior (typically closing the tab) before our predicate sees it. Middle-clicking on the **empty drag region** at the top of those windows still works for minimizing.

`Win+Shift+Z` is the universal fallback: it works in every app, every time, regardless of how that app handles middle-click.

### Theme does not auto-follow live Windows-wide theme changes

The theme is seeded from the Windows Apps theme on first install (or first launch for users upgrading from pre-v1.0.3), then persisted. If you later flip Windows Light↔Dark system-wide, the About dialog stays on whatever you last set. Flip the in-About toggle to bring it back in sync.

Also, the native Checkbox and OK Button get best-effort label recoloring across themes — their box icon and button chrome stay Windows-native, which can look slightly off against the Dark background.

### No crash recovery yet

If the program crashes hard while windows are hidden, those windows stay hidden until you restart the owning app or end its process via Task Manager. Apps with auto-save (Word, browsers, etc.) survive cleanly. A `--rescue` mode that enumerates hidden top-level windows and offers to restore them is parked for a follow-up release.

### Windows 11 collapsed-tray-icons mode

Per-app tray icons may hide in the overflow flyout. Functionality is identical, but you may want to pin the icons if you prefer them always visible.

### SmartScreen warning on first run

Releases are unsigned today. SmartScreen surfaces a warning on first run — click "More info" → "Run anyway". Code signing is a planned follow-up.

## Requirements

- Windows 10 or 11 (64-bit).

## Build from source

The repo vendors all build-time binaries under `dependencies/`, so **no AutoHotkey install is required** — a fresh clone can build the full Velopack release artifacts from source.

```powershell
.\build.ps1
```

Output (gitignored, in `dist/`):
- `minimize-to-tray-win-Setup.exe` (Velopack installer)
- `minimize-to-tray-win-Portable.zip` (portable archive)
- `minimize-to-tray-<version>-full.nupkg` (Velopack release package)
- `RELEASES`, `releases.win.json`, `assets.win.json` (Velopack feed manifests)

To stamp a custom version: `.\build.ps1 -Version '1.0.X'`.

Requirements:
- Windows PowerShell 5.1+ (ships with Windows 10/11) or PowerShell 7+.
- .NET 10 SDK (to compile the `updater-helper` companion .exe and to host the project-pinned `vpk` Velopack CLI).
- Nothing else — AutoHotkey runtime + Ahk2Exe + the Velopack runtime stub all vendored.

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

This project is built on top of [AutoHotkey](https://www.autohotkey.com/) ([github.com/AutoHotkey/AutoHotkey](https://github.com/AutoHotkey/AutoHotkey)), licensed under [GPL v2](dependencies/autohotkey/v2.0.26/LICENSE-AutoHotkey.txt). The AutoHotkey runtime is bundled into the compiled `minimize-to-tray.exe` (per Ahk2Exe's standard compilation model), so the executable is a combined work containing GPL-licensed components — distribution complies with GPL v2 terms.

Build-time compilation uses [Ahk2Exe](https://github.com/AutoHotkey/Ahk2Exe), licensed under [WTFPL v2](dependencies/autohotkey/ahk2exe/v1.1.37.02a2/LICENSE-Ahk2Exe.txt). Ahk2Exe is used only at build time and is not bundled into the output.

Distribution + in-app updates are managed by [Velopack](https://velopack.io), licensed under [MIT](https://github.com/velopack/velopack/blob/master/LICENSE). The Velopack runtime stub is bundled into the installer + portable archive.

The `minimize-to-tray` MIT license applies to the original `minimize-to-tray.ahk` source and any other original code in this repository.
