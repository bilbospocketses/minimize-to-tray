# Security Policy

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

Report security issues privately through GitHub's built-in security advisory flow:

**[Report a vulnerability](https://github.com/bilbospocketses/minimize-to-tray/security/advisories/new)**

This opens a private channel between you and the maintainer — no public disclosure until a fix is ready.

## What to Include

When reporting, please provide:

- A clear description of the vulnerability and its impact
- Steps to reproduce (proof-of-concept code, configuration, or environmental conditions)
- The affected version / commit
- Any mitigations you're aware of

## Response Expectations

- **Acknowledgement:** within **72 hours** of receipt
- **Triage and initial assessment:** within one week
- **Fix and disclosure timeline:** discussed with the reporter on a per-issue basis, depending on severity and complexity

## Supported Versions

Security fixes target the latest released version. Pre-1.0.0 versions and older releases are not maintained.

## Scope

In scope:
- The AutoHotkey v2 script (`minimize-to-tray.ahk`) and its Win32 API surface (`Shell_NotifyIcon`, `SetWinEventHook`, `ExtractIconEx`, hotkey + middle-click trigger handling).
- The .NET 10 `updater-helper.exe` and its Velopack `UpdateManager` integration (GitHub Releases feed).
- The Velopack-packaged installer (`minimize-to-tray-win-Setup.exe`) and update flow.

Out of scope:
- Vulnerabilities in AutoHotkey itself, Velopack, or the .NET runtime that have not been released against minimize-to-tray. Report those to their upstream projects.
- Issues requiring local administrative or physical access to a machine already running the app.
- Self-XSS or similar issues requiring the victim to paste attacker-controlled code into a console.
- Behavior of third-party apps whose windows are being minimized (e.g., a browser tab's middle-click handling) — this is documented in the README's Known Limitations.

Thanks for helping keep the project safe.
