# Update Notification Dialog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the update dot's silent-update behavior with a themed modal that shows the new version's release notes and only updates on explicit confirmation — mirroring tiny11options' CHANGELOG-auto-extract + raw-display pattern.

**Architecture:** Four touch points: (1) `build.ps1` extracts the `## [$Version]` CHANGELOG section and passes it to `vpk pack --releaseNotes` so Velopack embeds it in the feed; (2) `updater-helper.exe check` returns version + `NotesMarkdown`; (3) `minimize-to-tray.ahk` parses + stores the notes; (4) `minimize-to-tray.ahk` shows a themed `ShowUpdateDialog()` modal (modeled on the existing Exit-confirmation dialog) and the dot opens it instead of applying directly. No new files.

**Tech Stack:** AutoHotkey v2.0 (Gui modal, uxtheme dark-mode reuse), .NET 10 / Velopack 1.2.0 (`UpdateInfo.TargetFullRelease.NotesMarkdown`), PowerShell 5.1 (`build.ps1` regex extraction), Velopack `vpk pack --releaseNotes`.

**Spec:** [`docs/specs/2026-06-04-update-notification-design.md`](../specs/2026-06-04-update-notification-design.md)

**Testing approach:** No automated test harness (sub-decision C; mtt has none and the AHK UI isn't unit-testable). Verification is three-tier: `/validate` parse checks after each AHK edit, raw-mode `/devsimulateupdate` dialog smoke in both themes, a full `build.ps1` run that proves the notes embed, and the two-release end-to-end.

**Refinement vs. spec:** The spec suggested generalizing `SetAboutTitleBarDark` into `SetGuiTitleBarDark(gui, isDark)`. During planning, the existing **Exit-confirmation dialog** (`ApplyThemeToExitDialog`, minimize-to-tray.ahk:2246) proved to be the closer precedent — it inlines the DWM dark-titlebar call and calls `ApplyDarkModeToGui`. The update dialog mirrors that instead, so **no About code is touched**. Functionally identical theming, lower blast radius.

**Multi-session cwd discipline:** Every file path absolute. Every `git` command uses `git -C "C:/Users/jscha/source/repos/minimize-to-tray"`. Already on branch `update-notification-dialog` (spec already committed there).

**Local-dependencies:** AHK `/validate` and raw-run smoke use the **vendored** runtime `dependencies/autohotkey/v2.0.26/AutoHotkey64.exe`, not any system install.

---

## File Structure

```
build.ps1                                          $Version bump + CHANGELOG notes extraction + --releaseNotes
updater-helper/Program.cs                          DoCheckAsync emits NotesMarkdown
minimize-to-tray.ahk                               UpdateNotes state, parse, dialog, dot rewire, APP_VERSION
CHANGELOG.md                                       [1.0.21] section (load-bearing: build.ps1 reads it)
docs/specs/2026-06-04-update-notification-design.md  (already written + committed)
docs/plans/2026-06-04-update-notification.md       this plan
```

All AHK + PS + C# changes are surgical inserts/replaces into existing files. No new files.

---

## Task 1: Pre-flight — vendored-deps freshness check

**Files:** none (mandated by `todo_minimize_to_tray.md` "On project open" before any work). Surface findings; do NOT auto-bump.

- [ ] **Step 1.1: Query latest upstream tags**

```powershell
"AHK runtime : pinned v2.0.26   latest -> " + (gh release view --repo AutoHotkey/AutoHotkey --json tagName --jq .tagName)
"Ahk2Exe     : pinned v1.1.37.02a2 latest -> " + (gh release view --repo AutoHotkey/Ahk2Exe --json tagName --jq .tagName)
"Velopack    : pinned 1.2.0      latest -> " + (gh release view --repo velopack/velopack --json tagName --jq .tagName)
```

- [ ] **Step 1.2: Report**

If any are newer than pinned, surface to the user (current → new) — don't bump here. A newer dep may become the natural payload for the v1.0.22 test release (Task 13). If all current, note "deps current" and continue.

---

## Task 2: `build.ps1` — embed release notes + bump $Version

**Files:** Modify `C:/Users/jscha/source/repos/minimize-to-tray/build.ps1`

- [ ] **Step 2.1: Bump the default `$Version` to 1.0.21**

Find:

```powershell
[CmdletBinding()]
param(
    [string]$Version = '1.0.20',
    [switch]$SkipHelper
)
```

Replace with:

```powershell
[CmdletBinding()]
param(
    [string]$Version = '1.0.21',
    [switch]$SkipHelper
)
```

- [ ] **Step 2.2: Add the CHANGELOG extraction block before the pack invocation**

Find:

```powershell
Write-Host ('[3/3] vpk pack -> Velopack Setup.exe + bundle')
Write-Host ('      version : ' + $Version)
Write-Host ('      packDir : ' + $stagingDir)
Write-Host ('      mainExe : ' + $mainExeName)
Write-Host ('      icon    : ' + $icon)

Push-Location $repoRoot
```

Replace with:

```powershell
Write-Host ('[3/3] vpk pack -> Velopack Setup.exe + bundle')
Write-Host ('      version : ' + $Version)
Write-Host ('      packDir : ' + $stagingDir)
Write-Host ('      mainExe : ' + $mainExeName)
Write-Host ('      icon    : ' + $icon)

# Extract the release notes for $Version from CHANGELOG.md and hand them to vpk via
# --releaseNotes, so Velopack embeds them in the package + releases feed. The in-app
# update dialog reads them back through Velopack's NotesMarkdown. Mirrors tiny11options'
# CI extraction, but lives here because mtt packs inside build.ps1. The temp file is
# written OUTSIDE $stagingDir on purpose -- staging is the --packDir, so anything in it
# would get bundled into the app.
$changelogPath = Join-Path $repoRoot 'CHANGELOG.md'
$changelogText = Get-Content -LiteralPath $changelogPath -Raw
$notesPattern  = "(?ms)^## \[$([regex]::Escape($Version))\][^\n]*\n(.+?)(?=^## \[|\z)"
$notesMatch    = [regex]::Match($changelogText, $notesPattern)
if (-not $notesMatch.Success) {
    throw "No CHANGELOG.md section for version $Version. Expected a '## [$Version] - YYYY-MM-DD' header before building a release."
}
$releaseNotes = $notesMatch.Groups[1].Value.Trim()
$notesFile    = New-TemporaryFile
Set-Content -LiteralPath $notesFile.FullName -Value $releaseNotes -Encoding utf8
Write-Host ('      notes   : ' + $notesFile.FullName + ' (' + (($releaseNotes -split "`n").Count) + ' lines)')

Push-Location $repoRoot
```

- [ ] **Step 2.3: Pass `--releaseNotes` and clean up the temp file**

Find:

```powershell
try {
    & dotnet vpk pack `
        --packId      $packId `
        --packTitle   $packTitle `
        --packVersion $Version `
        --packAuthors $packAuth `
        --packDir     $stagingDir `
        --mainExe     $mainExeName `
        --icon        $icon `
        --outputDir   $distDir
    if ($LASTEXITCODE -ne 0) {
        throw "vpk pack failed with exit code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}
```

Replace with:

```powershell
try {
    & dotnet vpk pack `
        --packId      $packId `
        --packTitle   $packTitle `
        --packVersion $Version `
        --packAuthors $packAuth `
        --packDir     $stagingDir `
        --mainExe     $mainExeName `
        --icon        $icon `
        --releaseNotes $notesFile.FullName `
        --outputDir   $distDir
    if ($LASTEXITCODE -ne 0) {
        throw "vpk pack failed with exit code $LASTEXITCODE"
    }
} finally {
    Pop-Location
    Remove-Item -LiteralPath $notesFile.FullName -Force -ErrorAction SilentlyContinue
}
```

- [ ] **Step 2.4: Lint the script (parse only — don't run; it would clean dist/)**

```powershell
$null = [System.Management.Automation.Language.Parser]::ParseFile('C:/Users/jscha/source/repos/minimize-to-tray/build.ps1', [ref]$null, [ref]$errs); $errs
```

Expected: no parse errors emitted. (A full build runs later in Task 10, after the CHANGELOG section exists.)

---

## Task 3: `updater-helper/Program.cs` — `check` returns version + notes

**Files:** Modify `C:/Users/jscha/source/repos/minimize-to-tray/updater-helper/Program.cs`

- [ ] **Step 3.1: Emit `NotesMarkdown` after the version line**

Find:

```csharp
            var info = await manager.CheckForUpdatesAsync();
            if (info is not null)
            {
                // stdout: the new version string only. AHK script trims and compares to APP_VERSION.
                Console.WriteLine(info.TargetFullRelease.Version);
            }
            return 0;
```

Replace with:

```csharp
            var info = await manager.CheckForUpdatesAsync();
            if (info is not null)
            {
                // Contract with minimize-to-tray.ahk CheckForUpdateAsync:
                //   line 1   = the new version (trimmed + compared to APP_VERSION)
                //   line 2.. = the release notes (NotesMarkdown), shown raw in the update dialog
                Console.WriteLine(info.TargetFullRelease.Version);
                Console.WriteLine(info.TargetFullRelease.NotesMarkdown ?? "");
            }
            return 0;
```

- [ ] **Step 3.2: Verify the helper builds**

```powershell
& dotnet build 'C:/Users/jscha/source/repos/minimize-to-tray/updater-helper/UpdaterHelper.csproj' -c Release --nologo
```

Expected: `Build succeeded`, 0 errors.

---

## Task 4: AHK — `UpdateNotes` state, `APP_VERSION` bump, shared helpers

**Files:** Modify `C:/Users/jscha/source/repos/minimize-to-tray/minimize-to-tray.ahk`

- [ ] **Step 4.1: Add `UpdateNotes` global + bump `APP_VERSION`**

Find:

```ahk
global APP_VERSION      := "1.0.20"       ; embedded version, kept in sync with vpk pack --packVersion
global UpdateAvailable  := false         ; true if updater-helper.exe reports a newer release
global UpdateVersion    := ""            ; the new version string from the helper
```

Replace with:

```ahk
global APP_VERSION      := "1.0.21"       ; embedded version, kept in sync with vpk pack --packVersion
global UpdateAvailable  := false         ; true if updater-helper.exe reports a newer release
global UpdateVersion    := ""            ; the new version string from the helper
global UpdateNotes      := ""            ; release notes for UpdateVersion, from updater-helper check
```

- [ ] **Step 4.2: Add the `updateGui` global next to the About/dot globals**

Find:

```ahk
global aboutGui    := 0
global aboutDot    := 0
global pulseTimer  := 0
```

Replace with:

```ahk
global aboutGui    := 0
global aboutDot    := 0
global pulseTimer  := 0
global updateGui   := 0   ; the update-notification modal Gui (or 0 when closed)
```

- [ ] **Step 4.3: Verify parse**

```powershell
& 'C:/Users/jscha/source/repos/minimize-to-tray/dependencies/autohotkey/v2.0.26/AutoHotkey64.exe' /validate 'C:/Users/jscha/source/repos/minimize-to-tray/minimize-to-tray.ahk'
```

Expected: exit 0, no error dialog.

---

## Task 5: AHK — parse version+notes, seed dev-flag notes

**Files:** Modify `minimize-to-tray.ahk`

- [ ] **Step 5.1: Rewrite `CheckForUpdateAsync` to split version from notes**

Find (the whole function, lines ~986-1025):

```ahk
CheckForUpdateAsync() {
    global UpdateAvailable, UpdateVersion, A_IsCompiled, DevSimulateUpdate

    ; Dev short-circuit: /devsimulateupdate flag bypasses the helper entirely
    ; and just flips UpdateAvailable + AddUpdateDotToAbout. Smoke test for the
    ; live-inject path. The "!UpdateAvailable" guard prevents repeated triggers
    ; once already flipped (this function fires from multiple call sites).
    if (DevSimulateUpdate && !UpdateAvailable) {
        UpdateAvailable := true
        UpdateVersion := "1.0.99-dev"
        AddUpdateDotToAbout()
        return
    }

    ; Only check when running as compiled exe inside a Velopack install
    if (!A_IsCompiled)
        return

    helperPath := A_ScriptDir "\updater-helper.exe"
    if (!FileExist(helperPath))
        return

    try {
        shell := ComObject("WScript.Shell")
        exec := shell.Exec(Format('"{1}" check', helperPath))
        exec.StdIn.Close()
        result := Trim(exec.StdOut.ReadAll(), " `t`r`n")
        exitCode := exec.ExitCode
    } catch as err {
        return  ; helper failed; silently swallow
    }

    if (exitCode == 0 && result != "" && result != APP_VERSION) {
        UpdateAvailable := true
        UpdateVersion := result
        ; v1.0.5: if About is currently open, inject the dot live so the user
        ; sees it without having to close + reopen the dialog.
        AddUpdateDotToAbout()
    }
}
```

Replace with:

```ahk
CheckForUpdateAsync() {
    global UpdateAvailable, UpdateVersion, UpdateNotes, A_IsCompiled, DevSimulateUpdate

    ; Dev short-circuit: /devsimulateupdate flag bypasses the helper entirely and
    ; flips UpdateAvailable + seeds sample notes + AddUpdateDotToAbout. Smoke test
    ; for the live-inject path AND the update dialog. The "!UpdateAvailable" guard
    ; prevents repeated triggers once flipped (this fires from multiple call sites).
    if (DevSimulateUpdate && !UpdateAvailable) {
        UpdateAvailable := true
        UpdateVersion := "1.0.99-dev"
        UpdateNotes := DevSampleNotes()
        AddUpdateDotToAbout()
        return
    }

    ; Only check when running as compiled exe inside a Velopack install
    if (!A_IsCompiled)
        return

    helperPath := A_ScriptDir "\updater-helper.exe"
    if (!FileExist(helperPath))
        return

    try {
        shell := ComObject("WScript.Shell")
        exec := shell.Exec(Format('"{1}" check', helperPath))
        exec.StdIn.Close()
        raw := exec.StdOut.ReadAll()
        exitCode := exec.ExitCode
    } catch as err {
        return  ; helper failed; silently swallow
    }

    ; Contract with updater-helper check: line 1 = version, everything after the
    ; first newline = the notes blob. Normalize CRLF->LF first so the split is
    ; line-ending agnostic.
    raw := StrReplace(raw, "`r`n", "`n")
    nlPos := InStr(raw, "`n")
    if (nlPos) {
        verLine := Trim(SubStr(raw, 1, nlPos - 1), " `t`n")
        notesBlob := Trim(SubStr(raw, nlPos + 1), " `t`n")
    } else {
        verLine := Trim(raw, " `t`n")
        notesBlob := ""
    }

    if (exitCode == 0 && verLine != "" && verLine != APP_VERSION) {
        UpdateAvailable := true
        UpdateVersion := verLine
        UpdateNotes := notesBlob
        ; v1.0.5: if About is currently open, inject the dot live so the user
        ; sees it without having to close + reopen the dialog.
        AddUpdateDotToAbout()
    }
}
```

- [ ] **Step 5.2: Seed sample notes in the `/devshowdot` arg handler**

Find:

```ahk
    if (arg = "/devshowdot") {
        UpdateAvailable := true
        UpdateVersion := "1.0.99-dev"
    }
```

Replace with:

```ahk
    if (arg = "/devshowdot") {
        UpdateAvailable := true
        UpdateVersion := "1.0.99-dev"
        UpdateNotes := DevSampleNotes()
    }
```

- [ ] **Step 5.3: Verify parse** (note: `DevSampleNotes` is defined in Task 6; AHK resolves global funcs at load regardless of source order, so this validates clean only AFTER Task 6 lands — run the validate at the end of Task 6)

---

## Task 6: AHK — the update dialog + helpers

**Files:** Modify `minimize-to-tray.ahk`

Insert all new functions immediately AFTER `AddUpdateDotToAbout()` (which ends at the line `}` just before the `;====` "Triggers - handlers" banner near line 1051).

- [ ] **Step 6.1: Find the insertion anchor**

Find:

```ahk
    aboutGui.SetFont("s22 Bold cBlue", "Segoe UI Symbol")
    aboutDot := aboutGui.Add("Text", Format("x{1} y{2} w{3} h36 Center", dotX, dotY, iconW), Chr(9679))
    aboutDot.OnEvent("Click", OnClickUpdateDot)
    pulseTimer := PulseDot
    SetTimer(pulseTimer, 40)
}

;==============================================================================
; Triggers - handlers
;==============================================================================
```

Replace with (the same anchor, plus the new block inserted between the closing `}` and the banner):

```ahk
    aboutGui.SetFont("s22 Bold cBlue", "Segoe UI Symbol")
    aboutDot := aboutGui.Add("Text", Format("x{1} y{2} w{3} h36 Center", dotX, dotY, iconW), Chr(9679))
    aboutDot.OnEvent("Click", OnClickUpdateDot)
    pulseTimer := PulseDot
    SetTimer(pulseTimer, 40)
}

;==============================================================================
; Update-available notes dialog
;==============================================================================
; Clicking the pulsing dot opens this themed modal instead of updating silently.
; It shows the new version + its release notes (raw text, scrollable) and only
; runs the Velopack update when the user clicks "Update now". Structure + theming
; mirror the exit-confirmation dialog (ApplyThemeToExitDialog): BackColor + text
; colors + inline DWM dark title bar + ApplyDarkModeToGui for native controls.

NormalizeToCRLF(s) {
    ; Win32 Edit controls render line breaks only on CRLF. NotesMarkdown may arrive
    ; with bare LF (or already-CRLF). Collapse to LF, then expand to CRLF, so we
    ; never emit CR-CR-LF.
    return StrReplace(StrReplace(s, "`r`n", "`n"), "`n", "`r`n")
}

DevSampleNotes() {
    ; Multi-line sample so /devshowdot + /devsimulateupdate can exercise the dialog
    ; (scrolling, wrapping, theming) without a real release.
    return "### Added`n"
         . "- Update notification dialog: clicking the blue dot now shows what an update contains before installing.`n"
         . "`n"
         . "### Changed`n"
         . "- build.ps1 embeds the CHANGELOG section as Velopack release notes.`n"
         . "- updater-helper check now returns the version and its notes.`n"
         . "`n"
         . "### Notes`n"
         . "- This is sample text shown only under /devshowdot or /devsimulateupdate, long enough to demonstrate vertical scrolling and word wrapping inside the read-only notes box."
}

ShowUpdateDialog() {
    global updateGui, UpdateVersion, UpdateNotes, themeState

    ; Already open (double-click race) -> bring it forward.
    if (IsObject(updateGui)) {
        try updateGui.Show()
        return
    }

    updateGui := Gui("+AlwaysOnTop -MinimizeBox -MaximizeBox", "Update available")
    updateGui.OnEvent("Close",  (*) => CloseUpdateDialog())
    updateGui.OnEvent("Escape", (*) => CloseUpdateDialog())
    updateGui.MarginX := 18
    updateGui.MarginY := 16

    ; Header: app name + new version.
    updateGui.SetFont("s13 Bold", "Segoe UI")
    txtTitle := updateGui.AddText("xm w440", "minimize-to-tray  v" UpdateVersion)

    updateGui.SetFont("s10 Norm", "Segoe UI")
    txtWhat := updateGui.AddText("xm w440", "What's new:")

    ; Notes: read-only, multi-line (r14 rows), vertically scrollable. Win32 Edit
    ; needs CRLF; normalize first. Empty -> friendly fallback.
    notesText := (Trim(UpdateNotes) != "") ? NormalizeToCRLF(UpdateNotes) : "(No release notes provided.)"
    updateGui.SetFont("s9 Norm", "Consolas")
    edNotes := updateGui.Add("Edit", "xm w440 r14 ReadOnly VScroll", notesText)

    ; Buttons: Update now (default) + Later.
    updateGui.SetFont("s10 Norm", "Segoe UI")
    btnUpdate := updateGui.AddButton("xm w150 h32 Default", "&Update now")
    btnUpdate.OnEvent("Click", (*) => UpdateNowFromDialog())
    btnLater := updateGui.AddButton("x+10 yp w110 h32", "&Later")
    btnLater.OnEvent("Click", (*) => CloseUpdateDialog())

    ; Stash control refs on the Gui object (same pattern as the exit dialog).
    updateGui.txtTitle  := txtTitle
    updateGui.txtWhat   := txtWhat
    updateGui.edNotes   := edNotes
    updateGui.btnUpdate := btnUpdate
    updateGui.btnLater  := btnLater

    ApplyThemeToUpdateDialog()

    updateGui.Show("AutoSize Center")
}

ApplyThemeToUpdateDialog() {
    global updateGui, themeState
    if (!IsObject(updateGui))
        return
    pal := GetThemePalette(themeState)
    try updateGui.BackColor := pal.bg
    if (IsObject(updateGui.txtTitle))
        try updateGui.txtTitle.Opt("c" pal.title)
    if (IsObject(updateGui.txtWhat))
        try updateGui.txtWhat.Opt("c" pal.text)

    ; Notes box: theme its interior to match. In dark mode use the button-fill
    ; shade for subtle contrast against the dialog background; light mode stays
    ; white-on-black. (If a read-only Edit ignores the background on some Win10
    ; builds, the text stays readable regardless -- verified in the dark smoke.)
    if (IsObject(updateGui.edNotes)) {
        editBg := (themeState = "dark") ? pal.buttonBg : "FFFFFF"
        try updateGui.edNotes.Opt("Background" editBg " c" pal.text)
    }

    ; DWM dark title bar (attribute 20 = DWMWA_USE_IMMERSIVE_DARK_MODE).
    val := (themeState = "dark") ? 1 : 0
    try DllCall("dwmapi\DwmSetWindowAttribute"
        , "Ptr",  updateGui.Hwnd
        , "UInt", 20
        , "Int*", val
        , "UInt", 4)

    ; uxtheme dark-mode private API: theme native controls (Edit border/scrollbar,
    ; buttons) with DarkMode_Explorer in dark, Explorer in light.
    ApplyDarkModeToGui(updateGui, themeState)
}

CloseUpdateDialog() {
    global updateGui
    if (IsObject(updateGui)) {
        try updateGui.Destroy()
    }
    updateGui := 0
}

UpdateNowFromDialog() {
    ; The actual Velopack apply path, unchanged from the old OnClickUpdateDot:
    ; spawn the helper to download + apply + restart, then exit so OnExit fires
    ; and Velopack swaps the install.
    helperPath := A_ScriptDir "\updater-helper.exe"
    if (!FileExist(helperPath)) {
        MsgBox("Update helper missing at: " helperPath, "minimize-to-tray", "IconX")
        return
    }
    Run(Format('"{1}" update', helperPath))
    ExitApp()
}

;==============================================================================
; Triggers - handlers
;==============================================================================
```

- [ ] **Step 6.2: Verify parse**

```powershell
& 'C:/Users/jscha/source/repos/minimize-to-tray/dependencies/autohotkey/v2.0.26/AutoHotkey64.exe' /validate 'C:/Users/jscha/source/repos/minimize-to-tray/minimize-to-tray.ahk'
```

Expected: exit 0. (This now also validates Task 5's reference to `DevSampleNotes`.)

---

## Task 7: AHK — rewire the dot to open the dialog

**Files:** Modify `minimize-to-tray.ahk`

- [ ] **Step 7.1: Replace `OnClickUpdateDot`'s body**

Find:

```ahk
OnClickUpdateDot(*) {
    global UpdateAvailable
    if (!UpdateAvailable)
        return

    ; Spawn the Velopack helper to download + apply + restart.
    helperPath := A_ScriptDir "\updater-helper.exe"
    if (!FileExist(helperPath)) {
        MsgBox("Update helper missing at: " helperPath, "minimize-to-tray", "IconX")
        return
    }
    Run(Format('"{1}" update', helperPath))
    ; updater-helper handles the restart; our OnExit fires and Velopack swaps the install.
    ExitApp()
}
```

Replace with:

```ahk
OnClickUpdateDot(*) {
    global UpdateAvailable
    if (!UpdateAvailable)
        return
    ; v1.0.21: open the notes dialog instead of updating silently. The actual
    ; Velopack apply now runs from the dialog's "Update now" (UpdateNowFromDialog).
    ShowUpdateDialog()
}
```

- [ ] **Step 7.2: Verify parse**

```powershell
& 'C:/Users/jscha/source/repos/minimize-to-tray/dependencies/autohotkey/v2.0.26/AutoHotkey64.exe' /validate 'C:/Users/jscha/source/repos/minimize-to-tray/minimize-to-tray.ahk'
```

Expected: exit 0.

---

## Task 8: CHANGELOG `[1.0.21]`

**Files:** Modify `C:/Users/jscha/source/repos/minimize-to-tray/CHANGELOG.md`

- [ ] **Step 8.1: Add the section between `[Unreleased]` and `[1.0.20]`**

Find:

```markdown
## [Unreleased]

## [1.0.20] - 2026-06-04
```

Replace with:

```markdown
## [Unreleased]

## [1.0.21] - 2026-06-04

### Added
- **Update notification dialog.** Clicking the pulsing blue update dot in the About dialog now opens a themed dialog showing the new version and its release notes (what changed), with **Update now** / **Later** buttons — instead of silently downloading and installing. The notes are the new release's `CHANGELOG.md` section, embedded into the Velopack package at build time and read back via Velopack's `NotesMarkdown`. Mirrors the update-notification pattern in the sibling tiny11options project. The dialog is light/dark themed like the About and exit dialogs.

### Changed
- **`build.ps1` now embeds release notes.** Before packing, it extracts the `## [<version>]` section from `CHANGELOG.md` and passes it to `vpk pack --releaseNotes`, so the in-app updater can show what an update contains. A release build now requires a matching CHANGELOG section — the build fails fast if it is absent.
- **`updater-helper.exe check`** now prints the available version **and** its release notes (version on the first line, notes after), up from version-only. The `update` verb is unchanged.

## [1.0.20] - 2026-06-04
```

- [ ] **Step 8.2: Update the compare-link footer**

Find:

```markdown
[Unreleased]: https://github.com/bilbospocketses/minimize-to-tray/compare/v1.0.20...HEAD
[1.0.20]: https://github.com/bilbospocketses/minimize-to-tray/compare/v1.0.19...v1.0.20
```

Replace with:

```markdown
[Unreleased]: https://github.com/bilbospocketses/minimize-to-tray/compare/v1.0.21...HEAD
[1.0.21]: https://github.com/bilbospocketses/minimize-to-tray/compare/v1.0.20...v1.0.21
[1.0.20]: https://github.com/bilbospocketses/minimize-to-tray/compare/v1.0.19...v1.0.20
```

---

## Task 9: Raw-mode dialog smoke (both themes)

**Files:** none (testing only). Uses the vendored runtime + `/devsimulateupdate` — no compile needed (the dev short-circuit runs before the `A_IsCompiled` gate).

- [ ] **Step 9.1: Launch the raw script with the dev flag**

```powershell
Start-Process -FilePath 'C:/Users/jscha/source/repos/minimize-to-tray/dependencies/autohotkey/v2.0.26/AutoHotkey64.exe' -ArgumentList @('C:/Users/jscha/source/repos/minimize-to-tray/minimize-to-tray.ahk', '/devsimulateupdate')
```

- [ ] **Step 9.2: Light theme**

Single-left-click the tray icon → About opens. Within ~1s the pulsing blue dot injects (the on-open check fires the dev short-circuit). Ensure the theme toggle shows the **sun** (Light); if not, click it to switch to Light. Click the **blue dot**. Verify the update dialog:
- Header `minimize-to-tray  v1.0.99-dev`.
- "What's new:" + the sample notes in a read-only box; vertical scrollbar present; text wraps; scrolling works.
- **Update now** + **Later** buttons. **Later** / Esc closes; the dot remains in About.

- [ ] **Step 9.3: Dark theme**

In About, click the theme toggle to **moon** (Dark). Click the blue dot. Verify the dialog is dark: dark background, light title/label text, dark title bar, dark-themed buttons + scrollbar. **Confirm the notes box interior is dark (not a stark white box).** If it renders white, note it — the read-only Edit's `Background` isn't honored on this build; text is still readable, and the fix (a `WM_CTLCOLORSTATIC` handler) is a small follow-up, not a blocker.

- [ ] **Step 9.4: Update-now guard**

Click **Update now** in raw mode. Expected: a MsgBox "Update helper missing at: ...\updater-helper.exe" (there's no helper next to the raw script) — confirms the guard. Close it. Exit the script (right-click tray → Exit).

---

## Task 10: Full build — prove the notes embed

**Files:** Velopack build artifacts (local only; not committed).

- [ ] **Step 10.1: Build v1.0.21 locally**

```powershell
& 'C:/Users/jscha/source/repos/minimize-to-tray/build.ps1'
```

Expected: `[3/3]` prints a `notes : <temp> (N lines)` line; build completes; artifacts in `dist/` (Setup.exe, Portable.zip, `minimize-to-tray-1.0.21-full.nupkg`, RELEASES, releases.win.json, assets.win.json). This exercises Component 1 end-to-end, including the fail-fast path (the build only succeeds because Task 8 added the `## [1.0.21]` section).

- [ ] **Step 10.2: Confirm the notes rode into the feed**

```powershell
Select-String -Path 'C:/Users/jscha/source/repos/minimize-to-tray/dist/releases.win.json' -Pattern 'Update notification dialog' -SimpleMatch
```

Expected: a match — the CHANGELOG notes are present in `releases.win.json` (this is the field the in-app `check` reads back as `NotesMarkdown`).

---

## Task 11: PR + merge

**Files:** none (git/gh state).

- [ ] **Step 11.1: Stage + commit the implementation on the branch**

```powershell
git -C "C:/Users/jscha/source/repos/minimize-to-tray" add build.ps1 updater-helper/Program.cs minimize-to-tray.ahk CHANGELOG.md docs/plans/2026-06-04-update-notification.md
git -C "C:/Users/jscha/source/repos/minimize-to-tray" commit -m @'
feat: update-notification dialog; bump to v1.0.21

Clicking the update dot now opens a themed modal showing the new
version + its release notes (raw, scrollable) with Update now / Later,
instead of updating silently. Release notes are the version's
CHANGELOG.md section, embedded by build.ps1 via vpk pack --releaseNotes
and read back through Velopack NotesMarkdown -- mirroring tiny11options.

- build.ps1: extract "## [$Version]" from CHANGELOG.md -> --releaseNotes
  (fail-fast if the section is absent); bump $Version to 1.0.21.
- updater-helper check: emit version (line 1) + NotesMarkdown (line 2..).
- minimize-to-tray.ahk: UpdateNotes state, parse version/notes, new
  ShowUpdateDialog modeled on the exit dialog, dot opens it; APP_VERSION
  1.0.21. Dev flags seed sample notes for raw-mode smoke.
'@
```

- [ ] **Step 11.2: Push + open PR**

```powershell
git -C "C:/Users/jscha/source/repos/minimize-to-tray" push -u origin update-notification-dialog
gh pr create --repo bilbospocketses/minimize-to-tray --base main --head update-notification-dialog --title 'feat: update-notification dialog (v1.0.21)' --body 'Clicking the update dot now shows the new version + its release notes (Update now / Later) instead of updating silently. Notes = the version''s CHANGELOG.md section, embedded via `vpk pack --releaseNotes` in build.ps1 and read back through Velopack NotesMarkdown. See docs/specs/2026-06-04-update-notification-design.md and docs/plans/2026-06-04-update-notification.md.'
```

- [ ] **Step 11.3: Wait for required checks, then squash-merge**

```powershell
$pr = gh pr list --repo bilbospocketses/minimize-to-tray --head update-notification-dialog --json number --jq '.[0].number'
gh pr checks $pr --repo bilbospocketses/minimize-to-tray --watch --required
gh pr merge $pr --repo bilbospocketses/minimize-to-tray --squash --delete-branch
```

(Squash per the signed-repo merge rule — GitHub's web-flow key signs the squash commit so it satisfies `required_signatures`. Never `--rebase`.)

- [ ] **Step 11.4: Sync local main**

```powershell
git -C "C:/Users/jscha/source/repos/minimize-to-tray" switch main
git -C "C:/Users/jscha/source/repos/minimize-to-tray" pull origin main
```

---

## Task 12: Release v1.0.21 (the feature)

**Files:** none (tag triggers CI `release.yml`, which runs `build.ps1` + publishes).

- [ ] **Step 12.1: Tag signed on main + push**

```powershell
git -C "C:/Users/jscha/source/repos/minimize-to-tray" tag -s v1.0.21 -m 'v1.0.21 - update-notification dialog'
git -C "C:/Users/jscha/source/repos/minimize-to-tray" push origin v1.0.21
```

- [ ] **Step 12.2: Watch the release workflow**

```powershell
gh run watch (gh run list --repo bilbospocketses/minimize-to-tray --workflow release.yml --limit 1 --json databaseId --jq '.[0].databaseId') --repo bilbospocketses/minimize-to-tray --exit-status
```

Expected: success. Confirms `build.ps1` (with the new notes extraction) runs clean in CI and the release publishes.

- [ ] **Step 12.3: Verify the release feed carries the notes**

```powershell
gh release view v1.0.21 --repo bilbospocketses/minimize-to-tray --json tagName,assets --jq '{tag: .tagName, assets: [.assets[].name]}'
```

Expected: `releases.win.json`, `assets.win.json`, Setup.exe, Portable.zip, `*-full.nupkg`, RELEASES, SHA256SUMS present (the feed files carry the embedded notes for v1.0.21+ clients).

- [ ] **Step 12.4: Install v1.0.21** (so it's the running build that will see v1.0.22). Download + run `minimize-to-tray-win-Setup.exe` from the v1.0.21 release.

---

## Task 13: Release v1.0.22 (the test) + end-to-end verification

**Files:** `build.ps1`, `minimize-to-tray.ahk`, `CHANGELOG.md` (a small follow-up change + bumps).

v1.0.22 exists to give the installed v1.0.21 client something newer to notify about. Its payload is a deliberate choice — **make one small, genuine, changelog-worthy change.** Good candidates: a newer vendored dep surfaced by Task 1, or a minor polish (e.g. tighten the dialog wording). Whatever it is, it must have a `## [1.0.22]` CHANGELOG section (build.ps1 now requires it).

- [ ] **Step 13.1: New branch + make the chosen change**

```powershell
git -C "C:/Users/jscha/source/repos/minimize-to-tray" switch -c v1.0.22-notification-test
```

Apply the chosen small change.

- [ ] **Step 13.2: Bump versions + CHANGELOG**

- `build.ps1` `$Version` default → `'1.0.22'`.
- `minimize-to-tray.ahk` `APP_VERSION` → `"1.0.22"`.
- `CHANGELOG.md`: add `## [1.0.22] - <date>` describing the change; update the compare-link footer (`[Unreleased]` → `compare/v1.0.22...HEAD`; add `[1.0.22]: .../compare/v1.0.21...v1.0.22`).

- [ ] **Step 13.3: Local notes-embed check**

```powershell
& 'C:/Users/jscha/source/repos/minimize-to-tray/build.ps1'
Select-String -Path 'C:/Users/jscha/source/repos/minimize-to-tray/dist/releases.win.json' -Pattern '1.0.22' -SimpleMatch
```

Expected: build clean; the `1.0.22` notes section is present in the feed.

- [ ] **Step 13.4: PR + squash-merge + sync** (same shape as Task 11.2-11.4, head `v1.0.22-notification-test`).

- [ ] **Step 13.5: Tag + release**

```powershell
git -C "C:/Users/jscha/source/repos/minimize-to-tray" tag -s v1.0.22 -m 'v1.0.22 - notification test release'
git -C "C:/Users/jscha/source/repos/minimize-to-tray" push origin v1.0.22
gh run watch (gh run list --repo bilbospocketses/minimize-to-tray --workflow release.yml --limit 1 --json databaseId --jq '.[0].databaseId') --repo bilbospocketses/minimize-to-tray --exit-status
```

- [ ] **Step 13.6: End-to-end — the live proof**

On the running **v1.0.21** install from Task 12.4:
1. Open About (left-click the tray icon). Within the on-open check window, the blue dot appears (v1.0.22 detected).
2. Click the dot → the update dialog shows **`v1.0.22`** and **v1.0.22's CHANGELOG notes** (the real feed-sourced notes, not the dev sample).
3. Click **Update now** → the app downloads, applies, and restarts on v1.0.22.
4. Reopen About → version reads `v1.0.22`, no dot. Feature verified end-to-end.

---

## Self-review

**Spec coverage:**

| Spec requirement | Task |
| --- | --- |
| build.ps1 extracts `## [$Version]` → `--releaseNotes` | 2 |
| Fail-fast on missing CHANGELOG section (sub-decision A) | 2 |
| `check` returns version + `NotesMarkdown` | 3 |
| AHK stores notes (`UpdateNotes`) | 4, 5 |
| Parse: line 1 version, rest notes; CRLF-agnostic | 5 |
| Dev flags seed sample notes | 5, 6 (`DevSampleNotes`) |
| `ShowUpdateDialog`: header + version + scrollable raw notes + Update now/Later | 6 |
| Themed light/dark (reuse palette + ApplyDarkModeToGui + DWM titlebar) | 6 |
| CRLF normalization for the Edit (sub-decision: gotcha captured) | 6 (`NormalizeToCRLF`) |
| Empty-notes fallback | 6 |
| Leave About open behind modal (sub-decision B) | 6 (`+AlwaysOnTop`, no About teardown) |
| Dot opens dialog; Update now runs existing apply path | 6, 7 |
| No new test harness (sub-decision C) | 9 (raw smoke), 10 (build), 13 (E2E) |
| Local `/devsimulateupdate` both-themes smoke | 9 |
| v1.0.21 feature release, v1.0.22 test release | 12, 13 |
| No changes to release.yml / feed-upload / update verb | (none — confirmed) |

All in-scope spec requirements map to a task. No gaps.

**Placeholder scan:** No `TBD`/`TODO`/"implement later"/vague-validation phrasing. Task 13's payload is a documented, deliberate product choice (the test vehicle), not an implementation placeholder — its mechanics (bump/CHANGELOG/merge/tag/verify) are fully specified.

**Type/identifier consistency:** Names consistent across tasks — `UpdateNotes`, `updateGui`, `ShowUpdateDialog`, `ApplyThemeToUpdateDialog`, `CloseUpdateDialog`, `UpdateNowFromDialog`, `NormalizeToCRLF`, `DevSampleNotes`. Reused existing functions referenced with their real signatures: `GetThemePalette(name)`, `ApplyDarkModeToGui(guiObj, themeStateLocal)`, `AddUpdateDotToAbout()`, palette fields `bg`/`title`/`text`/`buttonBg`.

**Helper version note:** `updater-helper/UpdaterHelper.csproj` `<Version>` is `1.0.6` and has not tracked releases (cosmetic assembly version; the package version comes from `vpk pack --packVersion`). Left untouched to match the established convention. Flagged, not changed.
