# v1.0.3 Theme Toggle — Design Specification

**Date:** 2026-05-23
**Target release:** v1.0.3
**Status:** Approved (brainstorm) — pending writing-plans → implementation

## Project

Add a Light / Dark theme toggle to the About dialog. Persist the user's choice. Default for fresh installs follows the user's current Windows Apps theme. Click flips theme live without reopening the dialog.

## Motivation

v1.0.0–v1.0.2 hardcoded the About dialog to a Light palette (white background, dark text). Users running Windows in Dark mode get a stark white pop-up. A simple toggle solves the bad-contrast complaint and aligns with native Win11 Apps theme conventions.

## Scope

### In scope (v1.0.3)

- Two states only: **Light** and **Dark**.
- Toggle UI: a single Unicode-glyph Text control in the **top-right corner** of the About dialog.
  - Light theme active → display ☀ (U+2600 black sun) in a warm gold tint (`#D9A300`).
  - Dark theme active → display 🌙 (U+1F319 crescent-moon emoji, color-locked).
- Click toggle → flip theme **live** (no dialog reopen).
- Persistence: `HKEY_CURRENT_USER\Software\bilbospocketses\minimize-to-tray\Theme` = `"light"` | `"dark"` (REG_SZ).
- Fresh installs default to the user's Windows Apps theme at install time, written by the `--veloapp-install` hook.
- Existing v1.0.0 / v1.0.1 / v1.0.2 users updating to v1.0.3 get a one-time seeding on first v1.0.3 launch: if the `Theme` registry value is absent, read `AppsUseLightTheme` and persist the matching theme.
- When an update is available, the pulsing blue update dot **slides to the left of the theme icon** with a 12px gap.
- Hover tooltip on the theme toggle: `Switch to Dark theme` / `Switch to Light theme`.
- `--veloapp-uninstall` already wipes the entire app-scoped key — no change needed; `Theme` value goes with it.

### Out of scope (deferred indefinitely)

- Auto-following live Windows theme changes after first run (would need polling or a registry-watch hook).
- Full GDI+ owner-draw of the Checkbox + OK Button to make them pixel-perfect in Dark mode. The native controls accept best-effort label recoloring; their box/button rendering stays Windows-native.
- Theming the per-app tray-icon flyout menus or `ToolTip()` popups (Windows-native, already system-themed).
- Per-element typography changes between themes (font face, weight, size stay identical across themes — only colors flip).

## Architecture

Single-file edit to `minimize-to-tray.ahk`. No new files, no build-chain changes. Companion-helper `updater-helper.exe` is unaffected.

### State

```
APP_THEME_REG_VALUE := "Theme"            ; under existing APP_REG_KEY
themeState          := "light"            ; "light" | "dark", in-process truth
aboutThemeIcon      := 0                  ; AHK Gui Text handle for the toggle, or 0 when closed
aboutControlRefs    := { ... }            ; map of role -> control reference, used by ApplyTheme()
```

`themeState` is seeded at script init from the registry. If the registry value is missing (first v1.0.3 launch for an existing user, or any other reason), we fall back to reading `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize\AppsUseLightTheme` and persist the matching state, so subsequent launches stay stable.

### Velopack install hook seeding

In the existing `--veloapp-install` branch of the args loop, after the Run-on-login default and `FirstRunPending` writes, also seed the `Theme` value:

```ahk
if (arg = "--veloapp-install") {
    try RegWrite(A_ScriptFullPath, "REG_SZ", RUN_REG_KEY, RUN_REG_VALUE)
    try RegWrite(1, "REG_DWORD", APP_REG_KEY, FIRST_RUN_PENDING_REG_VALUE)
    initialTheme := ReadWindowsAppsTheme()    ; "light" or "dark"
    try RegWrite(initialTheme, "REG_SZ", APP_REG_KEY, APP_THEME_REG_VALUE)
    ExitApp 0
}
```

`ReadWindowsAppsTheme()`:

```ahk
ReadWindowsAppsTheme() {
    try {
        v := RegRead("HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme")
        return (v = 0) ? "dark" : "light"
    } catch {
        return "light"   ; safe default if the value's missing
    }
}
```

### Init-time seeding for upgrade path

Inside `Initialize()`, after `runOnLoginState` seeding:

```ahk
themeState := ReadRegistryTheme()
if (themeState = "") {
    themeState := ReadWindowsAppsTheme()
    if (A_IsCompiled)
        try RegWrite(themeState, "REG_SZ", APP_REG_KEY, APP_THEME_REG_VALUE)
}
```

`ReadRegistryTheme()` returns `""` on any read failure.

### Toggle action

```ahk
ToggleTheme(*) {
    themeState := (themeState = "light") ? "dark" : "light"
    if (A_IsCompiled)
        try RegWrite(themeState, "REG_SZ", APP_REG_KEY, APP_THEME_REG_VALUE)
    ApplyThemeToAbout()    ; live re-style; no-op if About not open
}
```

### Live re-style

`ApplyThemeToAbout()` does the heavy lifting:

1. Bail if `aboutGui` is 0 / not an object (toggle was triggered while About isn't open — shouldn't happen since the toggle lives inside About, but defensive).
2. Resolve a palette per `themeState`:
   ```
   light: bg=FFFFFF  title=000000  version=707070  shortcut=000000  italic=606060  url=0066CC  themeGlyphColor=D9A300
   dark:  bg=1F1F1F  title=F2F2F2  version=A0A0A0  shortcut=F2F2F2  italic=B8B8B8  url=4DA3FF  themeGlyphColor=  (color-locked emoji, no tint applied)
   ```
3. `aboutGui.BackColor := palette.bg`
4. For each known text control reference, call `.Opt("c<color>")` then `.Redraw()`.
5. Swap the theme-icon Text control's text to the appropriate glyph (`☀` or `🌙`) and its color (gold for sun, no tint for emoji moon — emoji ignores `c` attr anyway).
6. Re-style the Run-on-login checkbox label color via `Opt("c...")` (the box itself stays native).
7. Re-style the OK button: best-effort `Opt("c...")` on the label; native rendering otherwise.

### Layout update — update dot vs theme icon

Currently the update dot sits at `x = rightEdge - dotW + 20`, `y = 4`. The theme icon takes this position. When an update is available, the dot moves 44px to the left:

```
themeIconX := rightEdge - dotW + 20         ; same as old dotX
themeIconY := 4

dotX := themeIconX - dotW - 12              ; 12px gap; only used if UpdateAvailable
dotY := themeIconY
```

The theme icon is ALWAYS present in the About dialog. The update dot is conditional.

### Tooltip wiring

The theme icon needs a hover tooltip the same way the update dot does (cursor polling via `MouseGetPos` flag-2 + `ToolTip()`). Refactor the existing `UpdateDotTooltip` polling into a shared `UpdateAboutHoverTooltips` polling routine that handles both:

```ahk
UpdateAboutHoverTooltips() {
    static showing := ""    ; "", "dot", "theme"
    ; ... query cursor, decide which control (dot or theme icon) is under it, show matching tooltip
}
```

Started in `ShowAbout` if either the dot OR the theme icon is present (it's always present, so always started). Stopped in `CloseAbout`.

## Failure modes & edge cases

| Case | Behavior |
| --- | --- |
| Registry read fails on init (missing or permission issue) | Fall back to `ReadWindowsAppsTheme()`, persist the result, continue. |
| Registry write fails on toggle (e.g., locked-down user) | In-process `themeState` still flips; the About re-styles live for the session. Next launch reverts because the persist failed. Acceptable; no user-visible error. |
| Toggle clicked while About is in the middle of opening | `aboutGui` may not be fully constructed; the guard at top of `ApplyThemeToAbout` skips. Re-paint happens on the natural draw cycle. |
| Theme icon glyph fails to render (font missing for `🌙`) | Segoe UI Emoji ships with Win10/11 — this should never happen. If somehow it does, the Text control shows a missing-glyph placeholder; not crash-worthy. |
| `--veloapp-install` runs on a system with `AppsUseLightTheme` absent | `ReadWindowsAppsTheme()` catch returns `"light"`. Acceptable default. |
| Existing user updates from v1.0.2 → v1.0.3 with About closed | First normal launch seeds theme from Windows + persists. No About pops. |
| Existing user updates with About SOMEHOW open mid-update | Impossible — Velopack restarts the app as part of `apply`; about wouldn't survive. |

## Testing approach

Manual smoke walkthrough at first commit and again before tagging v1.0.3:

1. **Fresh install, Light Windows**: change Windows to Light Apps theme → uninstall any existing minimize-to-tray → install v1.0.3 → About pops post-install with Light theme; toggle shows ☀ (gold).
2. **Fresh install, Dark Windows**: same with Dark Apps theme → About pops Dark; toggle shows 🌙.
3. **Live flip**: open About → click toggle → background + text colors flip without dialog reopening; glyph swaps; `aboutGui.BackColor` updates immediately.
4. **Persistence**: toggle to opposite of install default → close About → reopen → theme persists in the new state. Restart the app → theme still persists.
5. **Layout with update dot**: force `/devshowdot` → open About → confirm theme icon is in top-right corner and the pulsing blue dot is 12px to its left.
6. **Tooltip**: hover the theme icon → "Switch to Dark theme" (or Light) appears. Hover the update dot (when present) → its existing tooltip appears.
7. **Upgrade path from v1.0.2**: install v1.0.2 first → upgrade in-app via the blue dot to v1.0.3 → first launch reads Windows theme, persists; About behaves correctly.
8. **Uninstall cleanup**: uninstall v1.0.3 → verify `HKCU\Software\bilbospocketses\minimize-to-tray\Theme` is gone (entire key wiped by existing `--veloapp-uninstall` cleanup).

No automated tests — same rationale as v1.0.0 (AHK has no standard test framework that justifies the setup for a single ~700-line script).

## Build / release

- Bump `APP_VERSION` in `minimize-to-tray.ahk` to `"1.0.3"`.
- Bump `<Version>` in `updater-helper/UpdaterHelper.csproj` to `1.0.3`.
- `build.ps1 -Version '1.0.3'` produces the standard 4 artifacts (Setup.exe + Portable.zip + .nupkg + RELEASES).
- CHANGELOG `[1.0.3]` section: theme toggle added, default-on-install behavior, registry value introduced; one-line note about the v1.0.2 → v1.0.3 upgrade seeding pattern.
- Tag v1.0.3 signed, push, gh release create with the 4 artifacts.

## Versioning note

Per user direction 2026-05-23, this feature ships as **v1.0.3** (patch bump), not v1.1.0. Small-utility convention: all small changes treated as patches even when adding features.
