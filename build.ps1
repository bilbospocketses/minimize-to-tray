#Requires -Version 5.1
<#
.SYNOPSIS
    Build the minimize-to-tray Velopack release.

.DESCRIPTION
    Three-stage build, all from vendored / project-pinned tools:
      1. Ahk2Exe compiles minimize-to-tray.ahk into a self-contained Windows .exe
         bundling the AutoHotkey v2 runtime stub and embedding the app icon + png.
      2. dotnet publishes updater-helper as a self-contained single-file .exe.
      3. dotnet vpk pack bundles both into a Velopack Setup.exe + .nupkg.

    All build-time binaries are vendored under dependencies/ or pinned in
    dotnet-tools.json (vpk). No system PATH dependency, no AutoHotkey install
    required. Per the project's Local-Dependencies-Only policy: a fresh clone
    can build this repo.

    PowerShell 5.1 compatible -- runs on stock Windows 10/11 without requiring
    pwsh 7+ installation.

.PARAMETER Version
    Override the version stamped into the Velopack package. Defaults to the
    APP_VERSION constant in minimize-to-tray.ahk (kept in sync there).

.PARAMETER SkipHelper
    Skip the updater-helper publish step (useful for iterating on AHK changes
    without re-publishing the helper, which adds ~10-15 seconds).

.NOTES
    Output (dist/): minimize-to-tray-win-Setup.exe + minimize-to-tray-win-Portable.zip
    + minimize-to-tray-<version>-full.nupkg + RELEASES + releases.win.json + assets.win.json.
#>

[CmdletBinding()]
param(
    [string]$Version = '1.0.19',
    [switch]$SkipHelper
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---- Paths -----------------------------------------------------------------
$repoRoot   = $PSScriptRoot
$srcAhk     = Join-Path $repoRoot 'minimize-to-tray.ahk'
$icon       = Join-Path $repoRoot 'assets\app.ico'
$png        = Join-Path $repoRoot 'assets\app.png'
$helperProj = Join-Path $repoRoot 'updater-helper\UpdaterHelper.csproj'
$distDir    = Join-Path $repoRoot 'dist'
$stagingDir = Join-Path $distDir  'staging'

# Vendored Ahk2Exe + AHK runtime
$ahkVer  = 'v2.0.26'
$a2eVer  = 'v1.1.37.02a2'
$ahkStub = Join-Path $repoRoot "dependencies\autohotkey\$ahkVer\AutoHotkey64.exe"
$ahk2exe = Join-Path $repoRoot "dependencies\autohotkey\ahk2exe\$a2eVer\Ahk2Exe.exe"

# Velopack package metadata
$packId    = 'minimize-to-tray'
$packTitle = 'minimize-to-tray'
$packAuth  = 'Jamie Chapman'

# ---- Sanity checks ---------------------------------------------------------
foreach ($f in @($srcAhk, $icon, $png, $helperProj, $ahkStub, $ahk2exe)) {
    if (-not (Test-Path -LiteralPath $f)) {
        throw "Missing required file: $f"
    }
}

# Clean dist/
if (Test-Path -LiteralPath $distDir) {
    Remove-Item -Recurse -Force -LiteralPath $distDir
}
New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null

# ---- Stage 1: Ahk2Exe ------------------------------------------------------
$mainExeName = "minimize-to-tray.exe"
$mainExePath = Join-Path $stagingDir $mainExeName

Write-Host ''
Write-Host ('[1/3] Ahk2Exe -> ' + $mainExeName)
Write-Host ('      src   : ' + $srcAhk)
Write-Host ('      icon  : ' + $icon)
Write-Host ('      base  : ' + $ahkStub)

# Ahk2Exe is a GUI subsystem app; PowerShell's `&` doesn't reliably set
# $LASTEXITCODE for GUI processes. Use Start-Process -Wait -PassThru for a
# deterministic ExitCode, then also verify the output file exists as a backstop.
$ahkArgs = @('/silent', '/in', $srcAhk, '/out', $mainExePath, '/icon', $icon, '/base', $ahkStub)
$proc = Start-Process -FilePath $ahk2exe -ArgumentList $ahkArgs -Wait -PassThru -NoNewWindow
if ($proc.ExitCode -ne 0) {
    throw "Ahk2Exe failed with exit code $($proc.ExitCode)"
}
if (-not (Test-Path -LiteralPath $mainExePath)) {
    throw "Ahk2Exe reported success but $mainExePath does not exist."
}
$mainSizeKB = [math]::Round((Get-Item -LiteralPath $mainExePath).Length / 1KB, 1)
Write-Host ('      built : ' + $mainSizeKB + ' KB')

# ---- Stage 2: dotnet publish updater-helper --------------------------------
$helperExeName = 'updater-helper.exe'
$helperOutDir  = Join-Path $stagingDir '_helper_publish'
$helperExePath = Join-Path $stagingDir $helperExeName

if ($SkipHelper.IsPresent) {
    Write-Host ''
    Write-Host '[2/3] Skipping updater-helper publish (--SkipHelper)'
    # Try to reuse the previous build under updater-helper/bin/publish
    $existing = Join-Path $repoRoot 'updater-helper\bin\publish\updater-helper.exe'
    if (-not (Test-Path -LiteralPath $existing)) {
        throw "SkipHelper set but no previous build at $existing. Run without -SkipHelper first."
    }
    Copy-Item $existing $helperExePath -Force
} else {
    Write-Host ''
    Write-Host ('[2/3] dotnet publish -> ' + $helperExeName)

    Push-Location $repoRoot
    try {
        & dotnet publish $helperProj -c Release -o $helperOutDir --nologo 2>&1 | ForEach-Object {
            if ($_ -match '^\s*$|^Microsoft \(R\)|^Copyright |^\s*Determining ') {} else { Write-Host "      $_" }
        }
        if ($LASTEXITCODE -ne 0) {
            throw "dotnet publish failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }

    $built = Join-Path $helperOutDir 'updater-helper.exe'
    if (-not (Test-Path -LiteralPath $built)) {
        throw "dotnet publish completed but $built does not exist."
    }
    Copy-Item $built $helperExePath -Force
    # Discard .pdb and the intermediate publish folder
    Remove-Item -Recurse -Force $helperOutDir
}
$helperSizeKB = [math]::Round((Get-Item -LiteralPath $helperExePath).Length / 1KB, 1)
Write-Host ('      built : ' + $helperSizeKB + ' KB')

# ---- Stage 3: vpk pack -----------------------------------------------------
Write-Host ''
Write-Host ('[3/3] vpk pack -> Velopack Setup.exe + bundle')
Write-Host ('      version : ' + $Version)
Write-Host ('      packDir : ' + $stagingDir)
Write-Host ('      mainExe : ' + $mainExeName)
Write-Host ('      icon    : ' + $icon)

Push-Location $repoRoot
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

# Clean the staging folder (no longer needed - vpk has packed everything)
if (Test-Path -LiteralPath $stagingDir) {
    Remove-Item -Recurse -Force -LiteralPath $stagingDir
}

# ---- Report ----------------------------------------------------------------
Write-Host ''
Write-Host '--- Build artifacts in dist/ ---'
Get-ChildItem -LiteralPath $distDir | Sort-Object Name | ForEach-Object {
    $sizeKB = [math]::Round($_.Length / 1KB, 1)
    Write-Host ('  {0,10:N1} KB  {1}' -f $sizeKB, $_.Name)
}
Write-Host ''
Write-Host 'Build complete.'
