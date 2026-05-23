# Vendored build dependencies

Binaries needed to build `minimize-to-tray.exe`, vendored into the repo per the
project's Local-Dependencies-Only policy. The repo is self-contained: anyone
with a clone can build without installing AutoHotkey.

| File | Version | Size | Source | Pin (SHA256) |
| --- | --- | ---: | --- | --- |
| [`autohotkey/v2.0.26/AutoHotkey64.exe`](autohotkey/v2.0.26/AutoHotkey64.exe) | v2.0.26 | 1.27 MB | [github.com/AutoHotkey/AutoHotkey @ v2.0.26](https://github.com/AutoHotkey/AutoHotkey/releases/tag/v2.0.26) (`AutoHotkey_2.0.26.zip` member) | `a2a54b8abc476d7671d4de0771bb54bf5f2373d79ff6871d0ba6a62c3b88ae00` |
| [`autohotkey/v2.0.26/LICENSE-AutoHotkey.txt`](autohotkey/v2.0.26/LICENSE-AutoHotkey.txt) | v2.0.26 | 18 KB | same | `b27c1a7c92686e47f8740850ad24877a50be23fd3dbd44edee50ac1223135e38` |
| [`autohotkey/ahk2exe/v1.1.37.02a2/Ahk2Exe.exe`](autohotkey/ahk2exe/v1.1.37.02a2/Ahk2Exe.exe) | v1.1.37.02a2 | 972 KB | [github.com/AutoHotkey/Ahk2Exe @ Ahk2Exe1.1.37.02a2](https://github.com/AutoHotkey/Ahk2Exe/releases/tag/Ahk2Exe1.1.37.02a2) (`Ahk2Exe1.1.37.02a2.zip` member) | (zip pin) `c29b8c3a5124850d79fc9e66e2ca79677c377d7f31631ad3022ba159c5d9e3be` |
| [`autohotkey/ahk2exe/v1.1.37.02a2/LICENSE-Ahk2Exe.txt`](autohotkey/ahk2exe/v1.1.37.02a2/LICENSE-Ahk2Exe.txt) | — | <1 KB | [github.com/AutoHotkey/Ahk2Exe @ master/COPYING](https://github.com/AutoHotkey/Ahk2Exe/blob/master/COPYING) | — |

## Licenses

- **AutoHotkey v2** is licensed under [GPL v2](autohotkey/v2.0.26/LICENSE-AutoHotkey.txt). The `AutoHotkey64.exe` runtime stub is the base that Ahk2Exe bundles into the compiled `minimize-to-tray.exe`, so the compiled output is a combined work containing GPL-licensed components — its distribution complies with GPL v2 terms (license text included, source available at the link above).
- **Ahk2Exe** is licensed under [WTFPL v2](autohotkey/ahk2exe/v1.1.37.02a2/LICENSE-Ahk2Exe.txt). Used only at build time; not bundled into the compiled output.

The `minimize-to-tray.ahk` source itself is licensed under MIT (see [`../LICENSE`](../LICENSE)).

## Refreshing vendored binaries

If a version bump is needed, the canonical commands (run from the repo root in PowerShell 5.1+):

```powershell
# AutoHotkey runtime
$url = 'https://github.com/AutoHotkey/AutoHotkey/releases/download/v<NEW_VERSION>/AutoHotkey_<NEW_VERSION>.zip'
# Download, verify SHA256, extract, copy AutoHotkey64.exe + license.txt into a new
# dependencies/autohotkey/v<NEW_VERSION>/ folder. Update build.ps1's $ahkVer.

# Ahk2Exe compiler
$url = 'https://github.com/AutoHotkey/Ahk2Exe/releases/download/Ahk2Exe<NEW_VERSION>/Ahk2Exe<NEW_VERSION>.zip'
# Download, verify SHA256, extract Ahk2Exe.exe into a new
# dependencies/autohotkey/ahk2exe/v<NEW_VERSION>/ folder. Refetch COPYING from master.
# Update build.ps1's $a2eVer.
```

The old version folder may be deleted in the same commit, OR kept around briefly during validation.
