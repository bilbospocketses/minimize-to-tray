# v1.0.3 Theme Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a live-flipping Light/Dark theme toggle to the About dialog, with persistence in the registry, seeded from the user's Windows Apps theme at install time.

**Architecture:** Single-file edit to `minimize-to-tray.ahk` (+ version bumps in `UpdaterHelper.csproj` + CHANGELOG). New `Theme` registry value under the existing `HKCU\Software\bilbospocketses\minimize-to-tray` key. Theme icon control replaces the dot's old top-right corner position; when an update is available, the dot slides 44px to the left of the theme icon. Click flips theme live via `ApplyThemeToAbout()` (no dialog reopen).

**Tech Stack:** AutoHotkey v2.0, registry I/O, AHK Gui control mutation (`Opt("c<color>")`, `BackColor :=`, `Redraw()`).

**Spec:** [`docs/specs/2026-05-23-theme-toggle-design.md`](../specs/2026-05-23-theme-toggle-design.md)

**Testing approach:** Manual smoke walkthrough per the spec's Testing section (8 cases). No automated tests — same rationale as v1.0.0/v1.0.1/v1.0.2.

**Multi-session cwd discipline:** Every file path absolute. Every `git` command uses `git -C "C:/Users/jscha/source/repos/minimize-to-tray"`. Already on branch `feat/v1.0.3-theme-toggle`.

---

## File Structure

Only one source file changes:

```
minimize-to-tray.ahk         single-file AHK app — all theme logic lives here
updater-helper/UpdaterHelper.csproj    <Version> bump only (1.0.2 → 1.0.3)
CHANGELOG.md                 [1.0.3] section added
docs/plans/2026-05-23-theme-toggle.md  this plan
docs/specs/2026-05-23-theme-toggle-design.md  (already written)
```

All AHK changes touch existing sections by surgical insert. No new files.

---

## Task 1: Add theme state constants + globals

**Files:** Modify `C:/Users/jscha/source/repos/minimize-to-tray/minimize-to-tray.ahk`

- [ ] **Step 1.1: Add `APP_THEME_REG_VALUE` next to the existing `FIRST_RUN_PENDING_REG_VALUE`**

Find this block (currently around line 80, in the Run-on-login state section):

```ahk
; App-scoped registry key for first-run signaling between the Velopack install
; hook and the first normal launch (used by v1.0.2's "show About after install").
global APP_REG_KEY                 := "HKEY_CURRENT_USER\Software\bilbospocketses\minimize-to-tray"
global FIRST_RUN_PENDING_REG_VALUE := "FirstRunPending"
```

Replace with:

```ahk
; App-scoped registry key. Values stored here:
;   FirstRunPending  (REG_DWORD)  v1.0.2: signals "show About on first launch after install"
;   Theme            (REG_SZ)     v1.0.3: "light" | "dark", current theme state
global APP_REG_KEY                 := "HKEY_CURRENT_USER\Software\bilbospocketses\minimize-to-tray"
global FIRST_RUN_PENDING_REG_VALUE := "FirstRunPending"
global APP_THEME_REG_VALUE         := "Theme"
```

- [ ] **Step 1.2: Add theme state globals after the existing Run-on-login state block**

Find:

```ahk
global runOnLoginState   := 0           ; in-process truth; seeded from registry at init
global aboutRunOnLoginCb := 0           ; About-dialog checkbox handle (or 0 when dialog closed)
```

After the second of these lines (and before the comment block introducing `APP_REG_KEY`), insert:

```ahk

; Light/Dark theme state. Same source-of-truth pattern as Run-on-login: in-process
; global seeded from registry at init, mirrored to registry on toggle when compiled.
global themeState        := "light"     ; "light" | "dark"; seeded in Initialize()
global aboutThemeIcon    := 0           ; About-dialog theme-toggle Text handle (or 0 when closed)
```

- [ ] **Step 1.3: Verify the script still parses**

```powershell
& 'C:/Program Files/AutoHotkey/v2/AutoHotkey.exe' /Validate 'C:/Users/jscha/source/repos/minimize-to-tray/minimize-to-tray.ahk'
```

Expected: no output, exit 0. (The `/Validate` flag parses without running.)

---

## Task 2: Add `ReadWindowsAppsTheme()` + `ReadRegistryTheme()` helpers

**Files:** Modify `minimize-to-tray.ahk`

- [ ] **Step 2.1: Add the two helpers next to the existing `ReadRegistryRunOnLogin`**

Find this function (in the Run-on-login section):

```ahk
ReadRegistryRunOnLogin() {
    global RUN_REG_KEY, RUN_REG_VALUE
    try {
        val := RegRead(RUN_REG_KEY, RUN_REG_VALUE)
        return (val != "") ? 1 : 0
    } catch {
        return 0
    }
}
```

Immediately AFTER it, add:

```ahk

ReadRegistryTheme() {
    ; Returns "light" | "dark" if the Theme value is present and valid, else "".
    global APP_REG_KEY, APP_THEME_REG_VALUE
    try {
        val := RegRead(APP_REG_KEY, APP_THEME_REG_VALUE)
        if (val = "light" || val = "dark")
            return val
    }
    return ""
}

ReadWindowsAppsTheme() {
    ; Returns "light" | "dark" based on the Windows Apps theme registry value.
    ; Falls back to "light" if AppsUseLightTheme is missing (some imaged installs).
    try {
        v := RegRead("HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme")
        return (v = 0) ? "dark" : "light"
    } catch {
        return "light"
    }
}
```

- [ ] **Step 2.2: Verify parse**

```powershell
& 'C:/Program Files/AutoHotkey/v2/AutoHotkey.exe' /Validate 'C:/Users/jscha/source/repos/minimize-to-tray/minimize-to-tray.ahk'
```

---

## Task 3: Extend `--veloapp-install` hook to seed Theme

**Files:** Modify `minimize-to-tray.ahk`

- [ ] **Step 3.1: Add Theme write to the `--veloapp-install` branch**

Find:

```ahk
    if (arg = "--veloapp-install") {
        ; Fresh install: default Run-on-login ON, and set a first-run marker so
        ; the normal-launch path that follows will surface the About dialog once
        ; (giving the user a chance to opt out of Run-on-login immediately).
        try RegWrite(A_ScriptFullPath, "REG_SZ", RUN_REG_KEY, RUN_REG_VALUE)
        try RegWrite(1, "REG_DWORD", APP_REG_KEY, FIRST_RUN_PENDING_REG_VALUE)
        ExitApp 0
    }
```

Replace with:

```ahk
    if (arg = "--veloapp-install") {
        ; Fresh install: default Run-on-login ON, seed Theme from the Windows Apps
        ; theme, and set a first-run marker so the normal-launch path that follows
        ; will surface the About dialog once (giving the user a chance to opt out
        ; of Run-on-login immediately and see the seeded theme).
        try RegWrite(A_ScriptFullPath, "REG_SZ", RUN_REG_KEY, RUN_REG_VALUE)
        try RegWrite(ReadWindowsAppsTheme(), "REG_SZ", APP_REG_KEY, APP_THEME_REG_VALUE)
        try RegWrite(1, "REG_DWORD", APP_REG_KEY, FIRST_RUN_PENDING_REG_VALUE)
        ExitApp 0
    }
```

- [ ] **Step 3.2: Verify parse**

```powershell
& 'C:/Program Files/AutoHotkey/v2/AutoHotkey.exe' /Validate 'C:/Users/jscha/source/repos/minimize-to-tray/minimize-to-tray.ahk'
```

---

## Task 4: Seed `themeState` in `Initialize()`

**Files:** Modify `minimize-to-tray.ahk`

- [ ] **Step 4.1: Add theme seeding after Run-on-login seeding in `Initialize()`**

Find this block in `Initialize()` (currently near the end):

```ahk
    ; Seed Run-on-login state from the registry and sync UI
    global runOnLoginState
    runOnLoginState := ReadRegistryRunOnLogin()
    UpdateRunOnLoginUI()
```

Replace with:

```ahk
    ; Seed Run-on-login state from the registry and sync UI
    global runOnLoginState
    runOnLoginState := ReadRegistryRunOnLogin()
    UpdateRunOnLoginUI()

    ; Seed theme state. Compiled installs are seeded by --veloapp-install; existing
    ; pre-v1.0.3 users get a one-time seed from the Windows Apps theme on first run.
    global themeState
    themeState := ReadRegistryTheme()
    if (themeState = "") {
        themeState := ReadWindowsAppsTheme()
        if (A_IsCompiled)
            try RegWrite(themeState, "REG_SZ", APP_REG_KEY, APP_THEME_REG_VALUE)
    }
```

- [ ] **Step 4.2: Verify parse**

```powershell
& 'C:/Program Files/AutoHotkey/v2/AutoHotkey.exe' /Validate 'C:/Users/jscha/source/repos/minimize-to-tray/minimize-to-tray.ahk'
```

---

## Task 5: Add palette resolution + `ApplyThemeToAbout()`

**Files:** Modify `minimize-to-tray.ahk`

- [ ] **Step 5.1: Add the palette + apply function after the Run-on-login section**

Find the end of `OnAboutRunOnLoginToggle`:

```ahk
OnAboutRunOnLoginToggle(ctrl, *) {
    SetRunOnLogin(ctrl.Value)
}
```

Immediately AFTER this function, add:

```ahk

;==============================================================================
; Light/Dark theme - palette + live apply
;==============================================================================
; Per-element colors are resolved here so ApplyThemeToAbout doesn't grow a giant
; if/else. The palette object's keys map 1:1 to the role keys used in
; aboutControlRefs (set up in ShowAbout when each themable control is created).

GetThemePalette(name) {
    if (name = "dark") {
        return {
            bg:        "1F1F1F",
            title:     "F2F2F2",
            version:   "A0A0A0",
            shortcut:  "F2F2F2",
            italic:    "B8B8B8",
            url:       "4DA3FF",
            checkbox:  "F2F2F2",
            okButton:  "F2F2F2",
            themeGlyph: ""        ; emoji moon is color-locked; tint is ignored
        }
    }
    ; light
    return {
        bg:        "FFFFFF",
        title:     "000000",
        version:   "707070",
        shortcut:  "000000",
        italic:    "606060",
        url:       "0066CC",
        checkbox:  "000000",
        okButton:  "000000",
        themeGlyph: "D9A300"      ; gold sun
    }
}

ApplyThemeToAbout() {
    ; Live re-style of the About dialog. No-op when the dialog isn't open.
    ; Iterates the role->control map populated in ShowAbout, applies the new
    ; color to each, then forces a redraw.
    global aboutGui, aboutControlRefs, aboutThemeIcon, themeState
    if (!aboutGui || !IsObject(aboutGui))
        return

    pal := GetThemePalette(themeState)
    try aboutGui.BackColor := pal.bg

    if (IsObject(aboutControlRefs)) {
        for role, ctrl in aboutControlRefs {
            if (!IsObject(ctrl))
                continue
            color := pal.%role%
            if (color != "") {
                try ctrl.Opt("c" color)
                try ctrl.Redraw()
            }
        }
    }

    ; Swap the theme-icon glyph + color
    if (IsObject(aboutThemeIcon)) {
        if (themeState = "dark") {
            try aboutThemeIcon.Text := Chr(0x1F319)  ; crescent moon emoji
        } else {
            try aboutThemeIcon.Text := Chr(0x2600)   ; classic sun
        }
        if (pal.themeGlyph != "")
            try aboutThemeIcon.Opt("c" pal.themeGlyph)
        try aboutThemeIcon.Redraw()
    }

    ; Force a top-level repaint so the BackColor change is visible immediately
    try aboutGui.Show("NoActivate")
}
```

- [ ] **Step 5.2: Verify parse**

```powershell
& 'C:/Program Files/AutoHotkey/v2/AutoHotkey.exe' /Validate 'C:/Users/jscha/source/repos/minimize-to-tray/minimize-to-tray.ahk'
```

---

## Task 6: Add `ToggleTheme()`

**Files:** Modify `minimize-to-tray.ahk`

- [ ] **Step 6.1: Add `ToggleTheme()` right after `ApplyThemeToAbout()`**

```ahk

ToggleTheme(*) {
    global themeState, APP_REG_KEY, APP_THEME_REG_VALUE
    themeState := (themeState = "light") ? "dark" : "light"
    if (A_IsCompiled) {
        try RegWrite(themeState, "REG_SZ", APP_REG_KEY, APP_THEME_REG_VALUE)
    }
    ApplyThemeToAbout()
}
```

- [ ] **Step 6.2: Verify parse**

```powershell
& 'C:/Program Files/AutoHotkey/v2/AutoHotkey.exe' /Validate 'C:/Users/jscha/source/repos/minimize-to-tray/minimize-to-tray.ahk'
```

---

## Task 7: Refactor `UpdateDotTooltip` into a shared hover routine

**Files:** Modify `minimize-to-tray.ahk`

- [ ] **Step 7.1: Replace the existing `UpdateDotTooltip` with a shared routine**

Find:

```ahk
UpdateDotTooltip() {
    global aboutGui, aboutDot, UpdateAvailable, UpdateVersion
    static showing := false

    if (!aboutGui || !IsObject(aboutGui) || !aboutDot || !IsObject(aboutDot) || !UpdateAvailable) {
        if (showing) {
            ToolTip()
            showing := false
        }
        return
    }

    try {
        MouseGetPos(, , , &ctrlHwnd, 2)   ; flag 2 = report control hwnd under cursor
    } catch {
        ctrlHwnd := 0
    }

    if (ctrlHwnd == aboutDot.Hwnd) {
        if (!showing) {
            ToolTip(
                "Update available: v" UpdateVersion "`n"
              . "Click to download and install.`n`n"
              . "minimize-to-tray`n"
              . "Win+Shift+Z or`n"
              . "Middle-click title bar`n"
              . "minimizes focused window to tray"
            )
            showing := true
        }
    } else if (showing) {
        ToolTip()
        showing := false
    }
}
```

Replace with:

```ahk
UpdateAboutHoverTooltips() {
    ; Single polling routine for all About-dialog hover tooltips. Tracks which
    ; control (if any) the cursor is over; shows the matching tooltip; dismisses
    ; on leave. Used by both the update dot and the theme toggle - AHK Text
    ; controls don't fire MouseEnter events, so we sample MouseGetPos at 100ms.
    global aboutGui, aboutDot, aboutThemeIcon, UpdateAvailable, UpdateVersion, themeState
    static showing := ""   ; "" | "dot" | "theme"

    if (!aboutGui || !IsObject(aboutGui)) {
        if (showing != "") {
            ToolTip()
            showing := ""
        }
        return
    }

    try {
        MouseGetPos(, , , &ctrlHwnd, 2)
    } catch {
        ctrlHwnd := 0
    }

    target := ""
    if (UpdateAvailable && IsObject(aboutDot) && ctrlHwnd == aboutDot.Hwnd) {
        target := "dot"
    } else if (IsObject(aboutThemeIcon) && ctrlHwnd == aboutThemeIcon.Hwnd) {
        target := "theme"
    }

    if (target = showing)
        return

    if (target = "dot") {
        ToolTip(
            "Update available: v" UpdateVersion "`n"
          . "Click to download and install.`n`n"
          . "minimize-to-tray`n"
          . "Win+Shift+Z or`n"
          . "Middle-click title bar`n"
          . "minimizes focused window to tray"
        )
    } else if (target = "theme") {
        otherTheme := (themeState = "light") ? "Dark" : "Light"
        ToolTip("Switch to " otherTheme " theme")
    } else {
        ToolTip()
    }
    showing := target
}
```

- [ ] **Step 7.2: Update the call sites that reference `UpdateDotTooltip`**

Find both occurrences of `UpdateDotTooltip` (one in `ShowAbout`, one in `CloseAbout`) and rename to `UpdateAboutHoverTooltips`. There are two:

In `ShowAbout`, after the dot is created:

```ahk
        SetTimer(UpdateDotTooltip, 100)
```

→

```ahk
        SetTimer(UpdateAboutHoverTooltips, 100)
```

In `CloseAbout`:

```ahk
    SetTimer(UpdateDotTooltip, 0)
```

→

```ahk
    SetTimer(UpdateAboutHoverTooltips, 0)
```

- [ ] **Step 7.3: Verify parse**

```powershell
& 'C:/Program Files/AutoHotkey/v2/AutoHotkey.exe' /Validate 'C:/Users/jscha/source/repos/minimize-to-tray/minimize-to-tray.ahk'
```

---

## Task 8: Add theme icon control + `aboutControlRefs` map + reposition dot in `ShowAbout`

**Files:** Modify `minimize-to-tray.ahk`

This is the largest task. We add the theme icon control (always present), populate `aboutControlRefs` with each themable control as we create it, and reposition the update dot to slide left when present.

- [ ] **Step 8.1: Initialize the `aboutControlRefs` map at the top of `ShowAbout`**

Find:

```ahk
ShowAbout(*) {
    global aboutGui, aboutDot, pulseTimer, APP_VERSION, UpdateAvailable, UpdateVersion

    ; If a previous About is still showing, just bring it forward.
    if (aboutGui && IsObject(aboutGui)) {
        try {
            aboutGui.Show()
            return
        }
    }
```

Replace with:

```ahk
ShowAbout(*) {
    global aboutGui, aboutDot, pulseTimer, APP_VERSION, UpdateAvailable, UpdateVersion
    global aboutThemeIcon, aboutControlRefs, themeState
    aboutControlRefs := Map()

    ; If a previous About is still showing, just bring it forward.
    if (aboutGui && IsObject(aboutGui)) {
        try {
            aboutGui.Show()
            return
        }
    }
```

- [ ] **Step 8.2: Capture title + version controls into the refs map**

Find the title + version block:

```ahk
    ; Title + version block - combined height ~36px, centered on imgCenterY (72).
    titleY := imgCenterY - 19   ; tuned so title baseline + version sit centered

    ; App image (now horizontally centered with the title block as one group)
    if (FileExist(appImagePath))
        aboutGui.Add("Picture", Format("x{1} y{2} w{3} h{3}", imgX, imgY, imgSize), appImagePath)

    aboutGui.SetFont("s16 Bold c000000", "Segoe UI")
    aboutGui.Add("Text", Format("x{1} y{2} w{3} Center", textStartX, titleY, textBlockW), "minimize-to-tray")

    aboutGui.SetFont("s9 Norm c707070", "Segoe UI")
    aboutGui.Add("Text", Format("x{1} y+4 w{2} Center", textStartX, textBlockW), "v" APP_VERSION)
```

Replace with:

```ahk
    ; Title + version block - combined height ~36px, centered on imgCenterY (72).
    titleY := imgCenterY - 19   ; tuned so title baseline + version sit centered

    ; App image (now horizontally centered with the title block as one group)
    if (FileExist(appImagePath))
        aboutGui.Add("Picture", Format("x{1} y{2} w{3} h{3}", imgX, imgY, imgSize), appImagePath)

    aboutGui.SetFont("s16 Bold c000000", "Segoe UI")
    aboutControlRefs["title"] := aboutGui.Add("Text", Format("x{1} y{2} w{3} Center", textStartX, titleY, textBlockW), "minimize-to-tray")

    aboutGui.SetFont("s9 Norm c707070", "Segoe UI")
    aboutControlRefs["version"] := aboutGui.Add("Text", Format("x{1} y+4 w{2} Center", textStartX, textBlockW), "v" APP_VERSION)
```

- [ ] **Step 8.3: Replace the update-dot block with the theme-icon + slid-left-dot block**

Find:

```ahk
    ; Pulsing dot at the top-right CORNER (decoupled from the title row vertically).
    ; Sits well above the title with comfortable top + right padding from the dialog
    ; corner, so it reads as a notification-style indicator rather than something
    ; squished next to the title.
    if (UpdateAvailable) {
        dotW       := 32
        rightEdge  := 28 + contentW
        dotX       := rightEdge - dotW + 20     ; 20px further right (extends into MarginX, dialog grows ~20px)
        dotY       := 4                         ; 4px below dialog top - tucked into the corner
        aboutGui.SetFont("s22 Bold cBlue", "Segoe UI Symbol")
        aboutDot := aboutGui.Add("Text", Format("x{1} y{2} w{3} h36 Center", dotX, dotY, dotW), Chr(9679))
        aboutDot.OnEvent("Click", OnClickUpdateDot)
        pulseTimer := PulseDot
        SetTimer(pulseTimer, 40)
        ; Cursor-on-control polling drives the hover tooltip (Text controls don't fire
        ; a MouseEnter event, so we sample MouseGetPos at 100ms instead).
        SetTimer(UpdateAboutHoverTooltips, 100)
    }
```

Replace with:

```ahk
    ; Top-right corner controls. Layout (left -> right):
    ;   [optional update dot]  [theme toggle]
    ; The theme toggle is ALWAYS present. The update dot is only created when
    ; an update is available, and slides 44px to the left of the theme icon.
    iconW       := 32
    rightEdge   := 28 + contentW
    themeIconX  := rightEdge - iconW + 20    ; same x as the old top-right dot
    themeIconY  := 4

    ; Update dot first (if applicable), so the layout below mirrors the visual
    ; left-to-right order.
    if (UpdateAvailable) {
        dotX := themeIconX - iconW - 12      ; 12px gap to the left of theme icon
        dotY := themeIconY
        aboutGui.SetFont("s22 Bold cBlue", "Segoe UI Symbol")
        aboutDot := aboutGui.Add("Text", Format("x{1} y{2} w{3} h36 Center", dotX, dotY, iconW), Chr(9679))
        aboutDot.OnEvent("Click", OnClickUpdateDot)
        pulseTimer := PulseDot
        SetTimer(pulseTimer, 40)
    }

    ; Theme toggle. Glyph + tint depend on current themeState. ApplyThemeToAbout
    ; (called at the end of ShowAbout) will normalize both, so the literal here
    ; just needs to be the right initial character for whichever theme is active.
    initialGlyph := (themeState = "dark") ? Chr(0x1F319) : Chr(0x2600)
    aboutGui.SetFont("s22 Bold cD9A300", "Segoe UI Symbol")
    aboutThemeIcon := aboutGui.Add("Text", Format("x{1} y{2} w{3} h36 Center", themeIconX, themeIconY, iconW), initialGlyph)
    aboutThemeIcon.OnEvent("Click", ToggleTheme)

    ; Single polling routine for both the dot and theme-icon hover tooltips.
    SetTimer(UpdateAboutHoverTooltips, 100)
```

- [ ] **Step 8.4: Capture shortcut + italic + URL controls into the refs map**

Find:

```ahk
    ; ---- Shortcut block ----
    ; Bumped down ~20px from the previous layout (request: more breathing room between
    ; the image/title cell and the shortcut block). Uses an absolute Y so the position
    ; is decoupled from the version control's y+N flow.
    shortcutY := imgY + imgSize + 24   ; image bottom + 24px breathing gap
    aboutGui.SetFont("s11 Norm c000000", "Segoe UI")
    aboutGui.Add("Text", Format("x28 y{1} w{2} Center", shortcutY, contentW),
                 "Win+Shift+Z   |   or   |   Middle-click on a title bar")

    aboutGui.SetFont("s10 Italic c606060", "Segoe UI")
    aboutGui.Add("Text", Format("x28 y+8 w{1} Center", contentW),
                 "minimize focused window to tray")
```

Replace with:

```ahk
    ; ---- Shortcut block ----
    ; Bumped down ~20px from the previous layout (request: more breathing room between
    ; the image/title cell and the shortcut block). Uses an absolute Y so the position
    ; is decoupled from the version control's y+N flow.
    shortcutY := imgY + imgSize + 24   ; image bottom + 24px breathing gap
    aboutGui.SetFont("s11 Norm c000000", "Segoe UI")
    aboutControlRefs["shortcut"] := aboutGui.Add("Text", Format("x28 y{1} w{2} Center", shortcutY, contentW),
                 "Win+Shift+Z   |   or   |   Middle-click on a title bar")

    aboutGui.SetFont("s10 Italic c606060", "Segoe UI")
    aboutControlRefs["italic"] := aboutGui.Add("Text", Format("x28 y+8 w{1} Center", contentW),
                 "minimize focused window to tray")
```

- [ ] **Step 8.5: Capture Run-on-login checkbox into the refs map and URL/OK controls**

Find:

```ahk
    aboutRunOnLoginCb := aboutGui.Add("Checkbox", "x28 y+20", "Run on login")
    aboutRunOnLoginCb.Value := IsRunOnLoginEnabled()
    aboutRunOnLoginCb.OnEvent("Click", OnAboutRunOnLoginToggle)
    aboutRunOnLoginCb.GetPos(, &cbY, &cbW, )
    aboutRunOnLoginCb.Move(28 + (contentW - cbW) // 2, cbY)
```

Replace with:

```ahk
    aboutRunOnLoginCb := aboutGui.Add("Checkbox", "x28 y+20", "Run on login")
    aboutRunOnLoginCb.Value := IsRunOnLoginEnabled()
    aboutRunOnLoginCb.OnEvent("Click", OnAboutRunOnLoginToggle)
    aboutRunOnLoginCb.GetPos(, &cbY, &cbW, )
    aboutRunOnLoginCb.Move(28 + (contentW - cbW) // 2, cbY)
    aboutControlRefs["checkbox"] := aboutRunOnLoginCb
```

Then find the URL + OK block:

```ahk
    githubUrl := "https://github.com/bilbospocketses/minimize-to-tray"
    aboutGui.SetFont("s9 Norm c0066CC Underline", "Segoe UI")
    urlCtrl := aboutGui.Add("Text", Format("x28 y+12 w{1} Center", contentW), githubUrl)
    urlCtrl.OnEvent("Click", (*) => Run(githubUrl))

    okX := 28 + (contentW - 96) // 2
    aboutGui.SetFont("s9 Norm c000000", "Segoe UI")
    aboutGui.Add("Button", Format("x{1} y+12 w96 h28 Default", okX), "OK")
            .OnEvent("Click", (*) => CloseAbout())
```

Replace with:

```ahk
    githubUrl := "https://github.com/bilbospocketses/minimize-to-tray"
    aboutGui.SetFont("s9 Norm c0066CC Underline", "Segoe UI")
    urlCtrl := aboutGui.Add("Text", Format("x28 y+12 w{1} Center", contentW), githubUrl)
    urlCtrl.OnEvent("Click", (*) => Run(githubUrl))
    aboutControlRefs["url"] := urlCtrl

    okX := 28 + (contentW - 96) // 2
    aboutGui.SetFont("s9 Norm c000000", "Segoe UI")
    okBtn := aboutGui.Add("Button", Format("x{1} y+12 w96 h28 Default", okX), "OK")
    okBtn.OnEvent("Click", (*) => CloseAbout())
    aboutControlRefs["okButton"] := okBtn
```

- [ ] **Step 8.6: Add `ApplyThemeToAbout()` call right before `aboutGui.Show()`**

Find:

```ahk
    aboutGui.OnEvent("Close",  (*) => CloseAbout())
    aboutGui.OnEvent("Escape", (*) => CloseAbout())

    aboutGui.Show("AutoSize Center")
}
```

Replace with:

```ahk
    aboutGui.OnEvent("Close",  (*) => CloseAbout())
    aboutGui.OnEvent("Escape", (*) => CloseAbout())

    ; Initial theme paint - applies background + per-control colors for the
    ; current themeState before the dialog is shown.
    ApplyThemeToAbout()

    aboutGui.Show("AutoSize Center")
}
```

- [ ] **Step 8.7: Verify parse**

```powershell
& 'C:/Program Files/AutoHotkey/v2/AutoHotkey.exe' /Validate 'C:/Users/jscha/source/repos/minimize-to-tray/minimize-to-tray.ahk'
```

---

## Task 9: Clear `aboutThemeIcon` + `aboutControlRefs` in `CloseAbout`

**Files:** Modify `minimize-to-tray.ahk`

- [ ] **Step 9.1: Add cleanup to `CloseAbout`**

Find:

```ahk
CloseAbout() {
    global aboutGui, aboutDot, pulseTimer, aboutRunOnLoginCb
    if (pulseTimer) {
        SetTimer(pulseTimer, 0)
        pulseTimer := 0
    }
    SetTimer(UpdateAboutHoverTooltips, 0)
    ToolTip()    ; dismiss any lingering hover tooltip
    if (aboutGui && IsObject(aboutGui)) {
        try aboutGui.Destroy()
    }
    aboutGui := 0
    aboutDot := 0
    aboutRunOnLoginCb := 0
}
```

Replace with:

```ahk
CloseAbout() {
    global aboutGui, aboutDot, pulseTimer, aboutRunOnLoginCb, aboutThemeIcon, aboutControlRefs
    if (pulseTimer) {
        SetTimer(pulseTimer, 0)
        pulseTimer := 0
    }
    SetTimer(UpdateAboutHoverTooltips, 0)
    ToolTip()    ; dismiss any lingering hover tooltip
    if (aboutGui && IsObject(aboutGui)) {
        try aboutGui.Destroy()
    }
    aboutGui := 0
    aboutDot := 0
    aboutRunOnLoginCb := 0
    aboutThemeIcon := 0
    aboutControlRefs := ""
}
```

- [ ] **Step 9.2: Verify parse**

```powershell
& 'C:/Program Files/AutoHotkey/v2/AutoHotkey.exe' /Validate 'C:/Users/jscha/source/repos/minimize-to-tray/minimize-to-tray.ahk'
```

---

## Task 10: Bump APP_VERSION

**Files:** Modify `minimize-to-tray.ahk` + `updater-helper/UpdaterHelper.csproj`

- [ ] **Step 10.1: AHK side**

```ahk
global APP_VERSION      := "1.0.2"
```

→

```ahk
global APP_VERSION      := "1.0.3"
```

- [ ] **Step 10.2: csproj side**

In `C:/Users/jscha/source/repos/minimize-to-tray/updater-helper/UpdaterHelper.csproj`:

```xml
<Version>1.0.2</Version>
```

→

```xml
<Version>1.0.3</Version>
```

---

## Task 11: Update CHANGELOG

**Files:** Modify `C:/Users/jscha/source/repos/minimize-to-tray/CHANGELOG.md`

- [ ] **Step 11.1: Add [1.0.3] section between [Unreleased] and [1.0.2]**

Find:

```markdown
## [Unreleased]

## [1.0.2] - 2026-05-23
```

Replace with:

```markdown
## [Unreleased]

## [1.0.3] - 2026-05-23

### Added
- Light / Dark theme toggle in the About dialog. Click the sun ☀ / moon 🌙 glyph in the top-right corner to flip; the dialog re-styles live (no reopen). Theme persists across launches at `HKCU\Software\bilbospocketses\minimize-to-tray\Theme`.
- Fresh installs seed the initial theme from the user's Windows Apps theme (`HKCU\...\Themes\Personalize\AppsUseLightTheme`) via the `--veloapp-install` hook. Existing v1.0.0 / v1.0.1 / v1.0.2 users updating to v1.0.3 get a one-time seed from the Windows theme on first launch and persist it.
- When the update-available blue dot is present, it now sits to the **left** of the theme toggle (12px gap) instead of in the top-right corner.

### Changed
- Native Checkbox (Run on login) and OK Button get best-effort label recoloring across themes; their box/button rendering stays Windows-native (documented out of scope for v1.0.3).

## [1.0.2] - 2026-05-23
```

- [ ] **Step 11.2: Add the v1.0.3 link footer**

Find:

```markdown
[Unreleased]: https://github.com/bilbospocketses/minimize-to-tray/compare/v1.0.2...HEAD
[1.0.2]: https://github.com/bilbospocketses/minimize-to-tray/releases/tag/v1.0.2
```

Replace with:

```markdown
[Unreleased]: https://github.com/bilbospocketses/minimize-to-tray/compare/v1.0.3...HEAD
[1.0.3]: https://github.com/bilbospocketses/minimize-to-tray/releases/tag/v1.0.3
[1.0.2]: https://github.com/bilbospocketses/minimize-to-tray/releases/tag/v1.0.2
```

---

## Task 12: First raw-AHK smoke

**Files:** none (testing only)

- [ ] **Step 12.1: Launch the raw script**

```powershell
Start-Process -FilePath 'C:/Program Files/AutoHotkey/v2/AutoHotkey.exe' -ArgumentList 'C:/Users/jscha/source/repos/minimize-to-tray/minimize-to-tray.ahk'
```

- [ ] **Step 12.2: Open About and verify initial theme**

Single-left-click the tray icon. The About dialog should open. The theme should match the current Windows Apps theme (Light → ☀ in top-right with gold tint; Dark → 🌙 in top-right, color-locked emoji).

- [ ] **Step 12.3: Verify live flip**

Click the theme icon. The dialog should re-style immediately:
- Background color flips (white ↔ dark gray)
- Title + version + shortcut + italic + URL + checkbox label flip to the opposite-contrast colors
- Theme icon glyph swaps (☀ ↔ 🌙) and color tint updates (gold sun in Light; color-locked moon in Dark)
- No dialog flicker / reopen — the same dialog instance updates in place

Click again to flip back. State should persist visually.

- [ ] **Step 12.4: Verify hover tooltip**

Hover the theme icon. Tooltip should appear: "Switch to Dark theme" (when Light is active) or "Switch to Light theme" (when Dark is active). Move cursor off → tooltip disappears.

- [ ] **Step 12.5: Verify update-dot layout (dev flag)**

Exit the running script (right-click tray → Exit), relaunch with the dev flag:

```powershell
Start-Process -FilePath 'C:/Program Files/AutoHotkey/v2/AutoHotkey.exe' -ArgumentList @('C:/Users/jscha/source/repos/minimize-to-tray/minimize-to-tray.ahk', '/devshowdot')
```

Open About. The pulsing blue dot should now be **to the left of the theme icon** (12px gap), both at the same y position. Hover the dot → its existing tooltip (update available + shortcuts reminder) appears. Hover the theme icon → its "Switch to ..." tooltip appears.

---

## Task 13: PR + merge

**Files:** none (git/gh state)

- [ ] **Step 13.1: Commit all changes on the feat branch**

```bash
git -C "C:/Users/jscha/source/repos/minimize-to-tray" add minimize-to-tray.ahk updater-helper/UpdaterHelper.csproj CHANGELOG.md docs/specs/2026-05-23-theme-toggle-design.md docs/plans/2026-05-23-theme-toggle.md
git -C "C:/Users/jscha/source/repos/minimize-to-tray" commit -m "feat: Light/Dark theme toggle in About; bump to v1.0.3

Adds a Light/Dark theme toggle to the top-right corner of the About
dialog. Click the sun/moon glyph to flip - dialog re-styles live, no
reopen. Theme persists at HKCU\Software\bilbospocketses\minimize-to-tray\Theme.
Fresh installs seed the initial theme from the Windows Apps theme via
the --veloapp-install hook. Existing v1.0.0 / v1.0.1 / v1.0.2 users get
a one-time seed on first v1.0.3 launch.

When the update-available blue dot is present, it now sits to the left
of the theme toggle (12px gap) instead of in the top-right corner.

Bumps APP_VERSION (AHK) + <Version> (csproj) to 1.0.3. CHANGELOG
[1.0.3] section added. Design spec + implementation plan committed
under docs/specs/ and docs/plans/."
```

- [ ] **Step 13.2: Push + create PR**

```bash
git -C "C:/Users/jscha/source/repos/minimize-to-tray" push -u origin feat/v1.0.3-theme-toggle
gh pr create --repo bilbospocketses/minimize-to-tray --base main --head feat/v1.0.3-theme-toggle --title 'feat: Light/Dark theme toggle in About; v1.0.3' --body 'Adds a live Light/Dark theme toggle in the top-right corner of About. Theme defaults to the Windows Apps theme at install time and persists in the registry. Update dot slides to the left of the theme icon when present. See docs/specs/2026-05-23-theme-toggle-design.md and docs/plans/2026-05-23-theme-toggle.md for the full design + plan.'
```

- [ ] **Step 13.3: Wait for CI green + squash-merge**

```bash
gh pr checks $(gh pr list --repo bilbospocketses/minimize-to-tray --head feat/v1.0.3-theme-toggle --json number --jq '.[0].number') --repo bilbospocketses/minimize-to-tray --watch --required
gh pr merge $(gh pr list --repo bilbospocketses/minimize-to-tray --head feat/v1.0.3-theme-toggle --json number --jq '.[0].number') --repo bilbospocketses/minimize-to-tray --squash --delete-branch
```

- [ ] **Step 13.4: Sync local main**

```bash
git -C "C:/Users/jscha/source/repos/minimize-to-tray" checkout main
git -C "C:/Users/jscha/source/repos/minimize-to-tray" pull origin main
git -C "C:/Users/jscha/source/repos/minimize-to-tray" branch -D feat/v1.0.3-theme-toggle
```

---

## Task 14: Build + tag + release

**Files:** Velopack build artifacts

- [ ] **Step 14.1: Build via build.ps1**

```powershell
& 'C:/Users/jscha/source/repos/minimize-to-tray/build.ps1' -Version '1.0.3'
```

Expected: clean build, artifacts at `dist/minimize-to-tray-win-Setup.exe`, `dist/minimize-to-tray-win-Portable.zip`, `dist/minimize-to-tray-1.0.3-full.nupkg`, `dist/RELEASES`.

- [ ] **Step 14.2: Tag signed**

```bash
git -C "C:/Users/jscha/source/repos/minimize-to-tray" tag -a v1.0.3 -m 'v1.0.3'
git -C "C:/Users/jscha/source/repos/minimize-to-tray" tag -v v1.0.3
git -C "C:/Users/jscha/source/repos/minimize-to-tray" push origin v1.0.3
```

- [ ] **Step 14.3: Create GitHub release**

```bash
gh release create v1.0.3 --repo bilbospocketses/minimize-to-tray \
  --title 'v1.0.3' \
  --notes 'Adds a Light/Dark theme toggle in the About dialog. Click the sun/moon glyph in the top-right to flip. Theme seeds from the Windows Apps theme at install time and persists across launches. Update-available blue dot now sits to the left of the theme icon when present. See CHANGELOG for full notes.' \
  "C:/Users/jscha/source/repos/minimize-to-tray/dist/minimize-to-tray-win-Setup.exe" \
  "C:/Users/jscha/source/repos/minimize-to-tray/dist/minimize-to-tray-win-Portable.zip" \
  "C:/Users/jscha/source/repos/minimize-to-tray/dist/minimize-to-tray-1.0.3-full.nupkg" \
  "C:/Users/jscha/source/repos/minimize-to-tray/dist/RELEASES"
```

- [ ] **Step 14.4: Verify release**

```bash
gh release view v1.0.3 --repo bilbospocketses/minimize-to-tray --json url,assets --jq '{url, assets: [.assets[] | {name, size}]}'
```

---

## Self-review

**Spec coverage:**

| Spec requirement | Task |
| --- | --- |
| Two states (Light/Dark) | 1, 2, 5, 6 |
| Persistence at HKCU\...\Theme | 1, 3, 4, 6 |
| Fresh install default = Windows Apps theme | 3 |
| Existing-user one-time seed on first v1.0.3 launch | 4 |
| Toggle UI top-right corner | 8 |
| ☀ + 🌙 glyphs | 5, 8 |
| Live re-style (no reopen) | 5, 6 |
| Update dot slides left of theme icon | 8 |
| Hover tooltip on toggle | 7 |
| Theme covers BackColor + text colors | 5 |
| Native Checkbox + OK Button best-effort label color | 5, 8 |
| Refactor UpdateDotTooltip → shared hover routine | 7 |
| Out of scope (live Windows theme follow, full owner-draw) | (not implemented — confirmed scope in spec) |
| Version bumps + CHANGELOG | 10, 11 |
| Build + tag + release | 14 |

All 15 in-scope spec requirements have explicit tasks. No gaps.

**Placeholder scan:** No `TBD` / `TODO` / `implement later` / vague-validation phrasing in any step.

**Type consistency:** Function and identifier names consistent across tasks (`themeState`, `aboutThemeIcon`, `aboutControlRefs`, `ApplyThemeToAbout`, `ToggleTheme`, `ReadRegistryTheme`, `ReadWindowsAppsTheme`, `GetThemePalette`, `UpdateAboutHoverTooltips`).
