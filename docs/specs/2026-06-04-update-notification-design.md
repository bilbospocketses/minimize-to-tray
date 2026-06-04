# Update Notification Dialog — Design Specification

**Date:** 2026-06-04
**Target releases:** v1.0.21 (feature) → v1.0.22 (end-to-end test)
**Status:** Approved (brainstorm) — pending writing-plans → implementation

## Project

When the user clicks the pulsing blue update dot in the About dialog, show a themed
modal dialog that tells them **what the update contains** (the new version's changelog),
and only run the Velopack update if they explicitly choose to. Today the dot updates
**silently**: one click downloads, applies, and restarts with no preview.

## Motivation

v1.0.0–v1.0.20 wire the dot's click straight to `updater-helper.exe update`
(`OnClickUpdateDot`, minimize-to-tray.ahk:967) — the app vanishes and restarts on the
new version with zero indication of what changed. A confirm-with-release-notes step
gives the user agency (see the changes, decide to install now or later) and matches the
pattern already shipping in the sibling **tiny11options** project.

## Reference — how tiny11options does it

tiny11options surfaces release notes through a clean producer → consumer chain that this
design mirrors:

- **Producer (`release.yml`):** a CI step regex-extracts the current version's
  `## [x.y.z]` section from `CHANGELOG.md` to a temp file, then `vpk pack --releaseNotes
  <file>` embeds it into the package and the `releases.win.json` feed.
- **Consumer (`VelopackUpdateSource.cs`):** reads it back at check time via
  `info.TargetFullRelease.NotesMarkdown`, packages `{version, changelog}`, and the
  WebView UI shows the changelog **raw** (`notesEl.textContent`) in a confirm modal with
  Cancel / Install buttons.

mtt mirrors this exactly, with two deliberate adaptations for mtt's architecture:

1. **The CHANGELOG extraction lives in `build.ps1`, not a CI step** — because mtt's `vpk
   pack` runs inside `build.ps1` (its `release.yml` just calls `./build.ps1`). This keeps
   mtt's "build.ps1 is the self-contained build brain; a fresh clone can build" ethos and
   means local builds embed notes too.
2. **The notification is a native AHK Gui dialog, not an HTML modal** — mtt is AHK with no
   WebView. It reuses the About dialog's theming machinery.

## Scope

### In scope (v1.0.21)

- `build.ps1` extracts the `## [$Version]` section of `CHANGELOG.md` and passes it to
  `vpk pack --releaseNotes`, so Velopack populates `NotesMarkdown` in the feed.
- `updater-helper.exe check` returns the new version **and** its release notes (today it
  returns only the version).
- `minimize-to-tray.ahk` stores the notes (`UpdateNotes` global), parsed from the helper's
  output.
- Clicking the update dot opens a new themed modal — **`ShowUpdateDialog()`** — showing:
  - header `minimize-to-tray   v<UpdateVersion>`
  - a "What's new:" label
  - a **read-only, scrollable** control with the release notes shown **raw** (no markdown
    processing, mirroring tiny's `textContent`)
  - **[Update now]** (default button) and **[Later]** buttons
- The dialog is light/dark themed via the existing palette + dark-mode helpers.
- **[Update now]** runs the existing `updater-helper.exe update` path (unchanged) + `ExitApp`.
  **[Later]** / Esc / close-X dismisses; the dot stays for next time.
- Dev flags (`/devshowdot`, `/devsimulateupdate`) seed sample `UpdateNotes` so the dialog
  is fully smoke-testable locally without publishing a release.

### Out of scope (deferred / not doing)

- **Markdown rendering.** Notes are shown raw, as tiny does. No bold/heading/bullet
  styling, no markdown → rich-text conversion.
- **OS toast notifications.** The notification is an in-app modal, not a Windows toast /
  Action Center entry. (Considered and rejected during brainstorm: transient, poor fit for
  a confirm-before-install gate, needs extra COM + AppUserModelID plumbing.)
- **Notes truncation.** tiny truncates to 400 chars because its modal is fixed-size; mtt
  uses a scrollable control and shows the whole section.
- **Showing cumulative notes across skipped versions.** Only the target (newest) release's
  notes are shown — that is what Velopack's `NotesMarkdown` returns for the update target.
- **A new automated test harness.** mtt's helper has no test project and the AHK UI is not
  unit-testable; verification is the dev-sim flag + the two staged releases (see Testing).
- **Changes to `release.yml`, the feed-upload list, or the `update` verb.**

## Architecture

Four touch points: `build.ps1`, `updater-helper/Program.cs`, `minimize-to-tray.ahk`
(parse + storage), `minimize-to-tray.ahk` (dialog + dot rewire). No new files.

### Data flow

```
build.ps1: extract "## [$Version]" from CHANGELOG.md  ──► temp notes file
   └► vpk pack --releaseNotes <temp file>
        └► Velopack package + releases.win.json  (notes ride in the feed)
             └► updater-helper.exe check  ──►  stdout:  line 1   = version
                                                        line 2.. = NotesMarkdown
                  └► minimize-to-tray.ahk CheckForUpdateAsync
                       └► UpdateVersion, UpdateNotes globals
                            └► (user clicks dot) OnClickUpdateDot → ShowUpdateDialog()
                                 └► [Update now] → updater-helper.exe update  (unchanged)
```

### Component 1 — `build.ps1`: embed release notes

Before the Stage-3 `vpk pack` call (~line 149), extract the matching CHANGELOG section
with tiny's exact regex, keyed off the existing `$Version` parameter:

```powershell
# ---- Extract release notes for $Version from CHANGELOG.md --------------------
$changelogPath = Join-Path $repoRoot 'CHANGELOG.md'
$changelog = Get-Content -LiteralPath $changelogPath -Raw
$pattern = "(?ms)^## \[$([regex]::Escape($Version))\][^\n]*\n(.+?)(?=^## \[|\z)"
$m = [regex]::Match($changelog, $pattern)
if (-not $m.Success) {
    throw "No CHANGELOG.md section for version $Version. Expected a '## [$Version] - YYYY-MM-DD' header."
}
$notes = $m.Groups[1].Value.Trim()
$notesFile = New-TemporaryFile      # OUTSIDE $stagingDir (staging IS --packDir; files there get bundled)
Set-Content -LiteralPath $notesFile -Value $notes -Encoding utf8
```

Pass `--releaseNotes $notesFile` to the `vpk pack` invocation, and remove `$notesFile`
in a `finally` so it never lingers.

- **Sub-decision A (approved): fail-fast.** Missing `## [$Version]` section → `throw`
  (mirrors tiny's `exit 1`). Enforces the changelog discipline already in practice; kills
  the silent-empty-notes failure mode. build.ps1 already updates `$Version` per release and
  the matching CHANGELOG section is authored at the same time.

### Component 2 — `updater-helper/Program.cs`: `check` returns version + notes

`DoCheckAsync` currently prints only the version (Program.cs:56). Add the notes line,
reading the same field tiny reads:

```csharp
if (info is not null)
{
    Console.WriteLine(info.TargetFullRelease.Version);             // line 1 (unchanged)
    Console.WriteLine(info.TargetFullRelease.NotesMarkdown ?? ""); // line 2..N (new)
}
return 0;
```

Single round-trip — the notes already ride in the feed that `CheckForUpdatesAsync`
fetches, so this adds no extra network cost. Contract: **line 1 = version, everything after
the first newline = notes.** The `check` exit-code semantics (always 0) and the `update`
verb are untouched.

### Component 3 — `minimize-to-tray.ahk`: parse + store

- New global alongside the other update-state globals (near line 64):
  ```ahk
  global UpdateNotes := ""   ; release notes for UpdateVersion, from updater-helper check
  ```
- In `CheckForUpdateAsync` (line 986), split the helper output into version (first line)
  and notes (remainder) instead of trimming the whole blob:
  ```ahk
  ; result = full stdout. First line is the version; the rest is the notes blob.
  newlinePos := InStr(result, "`n")
  if (newlinePos) {
      verLine := Trim(SubStr(result, 1, newlinePos - 1), " `t`r`n")
      notesBlob := Trim(SubStr(result, newlinePos + 1), " `t`r`n")
  } else {
      verLine := Trim(result, " `t`r`n")
      notesBlob := ""
  }
  if (exitCode == 0 && verLine != "" && verLine != APP_VERSION) {
      UpdateAvailable := true
      UpdateVersion := verLine
      UpdateNotes := notesBlob
      AddUpdateDotToAbout()
  }
  ```
- Dev flags set sample notes so the dialog can be exercised without a release:
  - `/devshowdot` (startup): set `UpdateNotes` to a short multi-line sample.
  - `/devsimulateupdate` (`CheckForUpdateAsync` short-circuit): same.

### Component 4 — `minimize-to-tray.ahk`: the modal + dot rewire

**Rewire the dot.** `OnClickUpdateDot` (line 967) stops applying directly and opens the
dialog instead:

```ahk
OnClickUpdateDot(*) {
    global UpdateAvailable
    if (!UpdateAvailable)
        return
    ShowUpdateDialog()
}
```

**New `ShowUpdateDialog()`**, built like `ShowAbout` and reusing the existing theming:

- A re-entrancy guard + global handle (`updateGui`), same pattern as `aboutGui`.
- `Gui("+AlwaysOnTop -MinimizeBox -MaximizeBox", "Update available")`, centered.
- Header Text: `minimize-to-tray` + `v<UpdateVersion>`.
- "What's new:" label.
- Notes control: a read-only multiline **`Edit`** (`+ReadOnly +Multi +VScroll +Wrap`)
  showing `UpdateNotes`, or the fallback `"(No release notes provided.)"` when empty.
  Read-only Edit gives native scrolling + copy for free. **Line endings:** normalize
  `UpdateNotes` to CRLF before assigning it — Win32 Edit controls render line breaks only
  on `\r\n`, and the helper's `NotesMarkdown` may arrive with bare `\n`.
- Buttons: **[Update now]** `Default` → the existing apply path; **[Later]** → close.
- Theming: reuse `GetThemePalette(themeState)` for colors and `ApplyDarkModeToGui(updateGui,
  themeState)` for native-control dark mode. Generalize the About-only
  `SetAboutTitleBarDark(isDark)` into `SetGuiTitleBarDark(gui, isDark)` (DWM attribute 20)
  and call it for both dialogs.

**[Update now]** carries the helper-existence check that lived in the old `OnClickUpdateDot`:

```ahk
UpdateNowFromDialog() {
    helperPath := A_ScriptDir "\updater-helper.exe"
    if (!FileExist(helperPath)) {
        MsgBox("Update helper missing at: " helperPath, "minimize-to-tray", "IconX")
        return
    }
    Run(Format('"{1}" update', helperPath))
    ExitApp()    ; updater-helper restarts us on the new version
}
```

- **Sub-decision B (approved): leave About open** behind the modal. The update dialog is
  `+AlwaysOnTop` on top of About; dismissing it returns to About. If z-order proves fiddly
  in testing, fall back to closing About on dot-click.
- Lifecycle: a `CloseUpdateDialog()` mirrors `CloseAbout()` (destroy + null the global).
  No pulse timer or hover-tooltip polling is needed inside this dialog.

## Failure modes & edge cases

| Case | Behavior |
| --- | --- |
| Release packaged before this feature (no `--releaseNotes`) → `NotesMarkdown` empty | `check` prints version + empty line; `UpdateNotes` = ""; dialog shows "(No release notes provided.)". Update still works. |
| `check` output is a single line (version only, no notes) | `InStr` finds no newline; `notesBlob` = ""; same fallback as above. |
| Notes contain blank leading line | `Trim` on `notesBlob` removes it. |
| `updater-helper.exe` missing at click time | Caught in `UpdateNowFromDialog` (MsgBox), same guard as the old `OnClickUpdateDot`. The dialog itself still opens (it shows stored notes, no helper needed to display). |
| CHANGELOG.md has no `## [$Version]` section at build time | `build.ps1` throws — release is not produced (fail-fast, sub-decision A). |
| User on ≤ v1.0.20 updates to v1.0.21 | No dialog — old clients have no display code; they update silently as before. The dialog is only seen by v1.0.21+ clients looking at a newer release. |
| Theme toggled in About, then dialog opened | `ShowUpdateDialog` reads current `themeState` at open, so it matches. (Live re-theming of an open update dialog is out of scope — it's transient.) |
| Dot clicked, dialog open, dot clicked again | Re-entrancy guard brings the existing dialog forward (same pattern as `ShowAbout`). |

## Testing approach

No new automated test harness (sub-decision C). Verification is two-tier:

**Local smoke (no release needed) — `/devsimulateupdate`:**
1. Launch compiled build with `/devsimulateupdate` → wait ~5s or open About → blue dot appears.
2. Click the dot → update dialog opens with the sample notes, scrollable, version shown.
3. Confirm **Light** and **Dark** theming both render correctly (toggle theme in About first).
4. **[Later]** dismisses, dot remains. Reopen via the dot works.
5. **[Update now]** with no real newer release: `update` reports no-update (helper exits 0,
   stderr only); app does not break. (Real apply is covered by the E2E below.)
6. Empty-notes path: temporarily blank the sample → dialog shows "(No release notes provided.)".

**End-to-end (the two staged releases):**
7. Build + release **v1.0.21**. Install it.
8. Build + release **v1.0.22** (small changelog-worthy follow-up).
9. On the running v1.0.21 install: open About → dot appears → click → dialog shows
   **v1.0.22's** CHANGELOG section → **[Update now]** → app restarts on v1.0.22.

## Build / release

Two releases, both patch bumps per the small-utility convention.

**v1.0.21 (feature):**
- Bump `APP_VERSION` in `minimize-to-tray.ahk` and `$Version` in `build.ps1` to `1.0.21`.
- Bump `<Version>` in `updater-helper/UpdaterHelper.csproj` to `1.0.21`.
- Add CHANGELOG `## [1.0.21]` describing the update-notification dialog + notes embedding.
  (Now load-bearing: `build.ps1` extracts it into the package.)
- `build.ps1` produces the standard artifacts, now including embedded release notes.
- Tag `v1.0.21` (signed), push, release with the existing asset set.

**v1.0.22 (test):**
- A small, genuine, changelog-worthy change. Same bump steps; CHANGELOG `## [1.0.22]`.
- This release's notes are what a v1.0.21 client displays — the live proof of the feature.

## Versioning note

Per standing user direction, both ship as **patch bumps** (v1.0.21, v1.0.22), not a MINOR
bump — small-utility convention: all small changes treated as patches even when adding a
user-facing feature.
