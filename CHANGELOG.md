# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.7] - 2026-05-24

### Added
- **Rescue mode.** Hidden windows are now tracked at `%LOCALAPPDATA%\bilbospocketses\minimize-to-tray\hidden.json` so a crash / force-kill / unclean exit no longer orphans windows. On next launch, if validated survivors exist (window still alive + PID + path match), a modal dialog appears with checkboxes per row: **Restore Selected** sends checked rows back to view and the rest back to the tray; **Restore All** brings everything back; **Send All to Tray** re-registers everything as tray-managed without re-hiding (entries already represent in-memory state after the call). Esc / Close-X behave like Send All to Tray. Atomic write via temp-file + `MoveFileEx` keeps the state file consistent under all exit paths.
- **Exit confirmation dialog.** Right-click the always-visible tray icon → Exit now asks "Restore & Exit" / "Leave Hidden" / "Cancel" if any windows are currently tray-managed. **Leave Hidden** is the use-case for crash recovery: windows stay hidden across the exit and next launch's rescue dialog will surface them. Zero-window fast-path skips the dialog entirely. Non-user-initiated exits (logoff, shutdown, Velopack update) keep the safe default: restore everything.
- **`Shift+Esc` diagnostic hotkey.** Snapshots the active window's Win32 + DWM state (HWND, class, title, process, path, rect, GWL_STYLE, GWL_EXSTYLE, GA_ROOTOWNER, DWMWA_CLOAKED, DWMWA_SYSTEMBACKDROP_TYPE) to the clipboard. Designed to characterize windows where `WinHide` is silently ignored (Electron / Chromium with Win11 system backdrops) so a future release can target the fix.

### Changed
- **Native Win11 dark/light theming for child controls.** Buttons, ListView, and checkboxes in the rescue / exit / About dialogs are now themed via uxtheme's `SetPreferredAppMode` + `AllowDarkModeForWindow` + `SetWindowTheme("DarkMode_Explorer"|"Explorer")` — the same engine File Explorer / Settings / Notepad++ use. Real hover / pressed states, real focus rings, real default-button accent borders, no hand-painted approximations. Replaces what was originally drafted as `BS_OWNERDRAW` + `WM_DRAWITEM` GDI owner-draw (~15 years dated, and AHK silently drops the `+0xB` option on `AddButton`).
- **Rescue dialog header.** Native LV header is suppressed (`-Hdr`); three bold Text labels above the ListView serve as column headers, framed with a 7-line grid (5 vertical separators positioned via `LVM_GETCOLUMNWIDTH` + device-pixel `SetWindowPos` for pixel-perfect alignment with the LV body grid at any DPI scale; 2 horizontal dividers). `gridLine` palette entry tuned to match the LV body's auto-drawn grid color in both themes.
- **"Hidden at" column shows local time.** Storage stays ISO 8601 UTC for portability; display converts to local "HH:mm" via `A_Now - A_NowUTC` offset.
- **Exit dialog body shortened.** "Restore all before exiting or leave hidden? Hidden apps can't be recovered after log off or restart." Replaces a longer paragraph.

## [1.0.6] - 2026-05-23

### Added
- `/devsimulateupdate` command-line flag: dev/smoke-test flag that short-circuits the helper call and flips `UpdateAvailable` on the next `CheckForUpdateAsync` tick (startup +5s OR on About open). Demonstrates the v1.0.5 live-inject behavior end-to-end without needing to publish a fake newer release. Companion to the existing `/devshowdot` flag (which forces the dot present from the first About open instead).

## [1.0.5] - 2026-05-23

### Added
- Update-available blue dot is now live-injected into an already-open About dialog when the update check (fired either at startup or on About open) detects a newer release. Previously, the dot only appeared on the NEXT About open after a positive check. New `AddUpdateDotToAbout()` helper bails cleanly if About isn't open, the dot is already present, or the theme icon (which anchors the dot's position) is missing.

## [1.0.4] - 2026-05-23

### Fixed
- Brief console window flash when `updater-helper.exe` runs the update check. `UpdaterHelper.csproj` `<OutputType>` changed from `Exe` (console subsystem) to `WinExe` (windows subsystem) so Windows no longer allocates a console at process start. stdout / stderr still pipe back to AHK because the parent launches with redirected handles.

### Added
- Fire an update check whenever the About dialog opens (in addition to the existing 5-seconds-after-startup check). If the user keeps the app running for a long time and opens About, the dot reflects the latest state. Helper call is scheduled via `SetTimer(CheckForUpdateAsync, -1)` so the dialog renders first. If an update is detected while About is already open, the dot appears on the next open (live-injecting into an open dialog is deferred).

## [1.0.3] - 2026-05-23

### Added
- Light / Dark theme toggle in the About dialog. Click the sun ☀ / moon 🌙 glyph in the top-right corner to flip; the dialog re-styles live (no reopen). Theme persists across launches at `HKCU\Software\bilbospocketses\minimize-to-tray\Theme`.
- Fresh installs seed the initial theme from the user's Windows Apps theme (`HKCU\...\Themes\Personalize\AppsUseLightTheme`) via the `--veloapp-install` hook. Existing v1.0.0 / v1.0.1 / v1.0.2 users updating to v1.0.3 get a one-time seed from the Windows theme on first launch and persist it.
- When the update-available blue dot is present, it now sits to the **left** of the theme toggle (12px gap) instead of in the top-right corner.

### Changed
- Native Checkbox (Run on login) and OK Button get best-effort label recoloring across themes; their box/button rendering stays Windows-native (documented out of scope for v1.0.3).

## [1.0.2] - 2026-05-23

### Added
- Show About dialog automatically once after a fresh install, so the user sees (and can immediately opt out of) the Run-on-login default. Subsequent launches behave as before. (Updates from v1.0.0 / v1.0.1 do NOT trigger the post-install About — only fresh installs do.)
- Default Run-on-login to ON for fresh installs. Existing v1.0.0 / v1.0.1 users updating to v1.0.2 retain whatever Run-on-login setting they already had.

### Changed
- `--veloapp-uninstall` now also wipes the entire `HKCU\Software\bilbospocketses\minimize-to-tray` registry key (in addition to the existing Run-on-login value cleanup) so no app-scoped state lingers post-uninstall.

## [1.0.1] - 2026-05-23

### Fixed
- Velopack lifecycle-hook handling. The main `minimize-to-tray.exe` is a native AHK-compiled binary (not .NET), so it didn't recognize the `--veloapp-install` / `--veloapp-updated` / `--veloapp-obsoleted` / `--veloapp-uninstall` args that Velopack passes during install / update / uninstall. The installer would launch the app normally and wait for the hook to exit, eventually surfacing "the application install hook failed". The hook handler now exits cleanly on any `--veloapp-*` arg, and `--veloapp-uninstall` additionally wipes the Run-on-login registry value so Windows doesn't keep trying to launch a no-longer-installed exe at login.

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

[Unreleased]: https://github.com/bilbospocketses/minimize-to-tray/compare/v1.0.6...HEAD
[1.0.6]: https://github.com/bilbospocketses/minimize-to-tray/releases/tag/v1.0.6
[1.0.5]: https://github.com/bilbospocketses/minimize-to-tray/releases/tag/v1.0.5
[1.0.4]: https://github.com/bilbospocketses/minimize-to-tray/releases/tag/v1.0.4
[1.0.3]: https://github.com/bilbospocketses/minimize-to-tray/releases/tag/v1.0.3
[1.0.2]: https://github.com/bilbospocketses/minimize-to-tray/releases/tag/v1.0.2
[1.0.1]: https://github.com/bilbospocketses/minimize-to-tray/releases/tag/v1.0.1
[1.0.0]: https://github.com/bilbospocketses/minimize-to-tray/releases/tag/v1.0.0
