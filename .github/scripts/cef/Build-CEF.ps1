#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Build a patched OBS Chromium Embedded Framework (CEF) minimal distribution
    for Windows.

.DESCRIPTION
    Wraps CEF's canonical automate-git.py build against OBS's *patched* CEF
    fork (the shared-texture / OnAcceleratedPaint + stutter-fix patches that
    obs-browser depends on) and repackages the result to the file name that
    obs-studio's dependency resolver expects, e.g.

        cef_binary_7204_windows_x64_v1.zip
        cef_binary_7204_windows_arm64_v1.zip

    A full Chromium build needs ~100+ GB free disk, 32+ GB RAM and several
    hours. Use a large/self-hosted runner. The GN defines here are a documented
    starting point; reconcile them against the obsproject/cef recipe of the
    branch you forked before distributing.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $CefBranch,        # e.g. 7204
    [Parameter(Mandatory)] [string] $CefRepoUrl,       # e.g. https://github.com/patcharapon-j/cef.git
    [Parameter(Mandatory)] [string] $CefRepoBranch,    # e.g. 7204-shared-textures-and-fixes
    [ValidateSet('x64', 'arm64')] [string] $TargetArch = 'x64',
    [int] $CefRevision = 1,
    [string] $WorkDir = (Join-Path $PWD 'cef-build'),
    [string] $OutputDir = (Join-Path $PWD 'cef-artifacts')
)

$ErrorActionPreference = 'Stop'

Write-Host "==> Building OBS CEF $CefBranch for windows/$TargetArch"
Write-Host "    fork: $CefRepoUrl @ $CefRepoBranch"

New-Item -ItemType Directory -Force -Path $WorkDir, $OutputDir | Out-Null
Set-Location $WorkDir

# --- depot_tools ------------------------------------------------------------
$depotTools = Join-Path $WorkDir 'depot_tools'
if (-not (Test-Path $depotTools)) {
    git clone --depth=1 https://chromium.googlesource.com/chromium/tools/depot_tools.git $depotTools
}
$env:PATH = "$depotTools;$env:PATH"
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'
$env:DEPOT_TOOLS_UPDATE = '1'

# --- automate-git.py --------------------------------------------------------
if (-not (Test-Path 'automate-git.py')) {
    Invoke-WebRequest -UseBasicParsing `
        -Uri 'https://bitbucket.org/chromiumembedded/cef/raw/master/tools/automate/automate-git.py' `
        -OutFile 'automate-git.py'
}

# --- GN defines -------------------------------------------------------------
$env:GN_DEFINES = 'is_official_build=true use_thin_lto=false chrome_pgo_phase=0 ' +
                  'proprietary_codecs=true ffmpeg_branding=Chrome symbol_level=1 enable_widevine=false'
$env:CEF_ARCHIVE_FORMAT = 'zip'

$automateArch = if ($TargetArch -eq 'arm64') { '--arm64-build' } else { '--x64-build' }

# --- Build ------------------------------------------------------------------
python automate-git.py `
    --download-dir="$WorkDir\chromium_git" `
    --branch="$CefBranch" `
    --url="$CefRepoUrl" `
    --checkout="$CefRepoBranch" `
    --minimal-distrib `
    --client-distrib `
    --force-clean `
    --no-debug-build `
    $automateArch

# --- Repackage to the obs-studio file-name contract ------------------------
$distribRoot = Join-Path $WorkDir 'chromium_git\chromium\src\cef\binary_distrib'
$srcDir = Get-ChildItem -Path $distribRoot -Directory -Filter 'cef_binary_*_minimal' |
          Select-Object -First 1
if (-not $srcDir) {
    throw "Could not locate the minimal distribution under $distribRoot"
}

$outName = "cef_binary_${CefBranch}_windows_${TargetArch}_v${CefRevision}"
$zipPath = Join-Path $OutputDir "$outName.zip"
Write-Host "==> Writing $zipPath"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

# obs-studio strips the top-level directory on extract, so archive the
# distribution contents directly.
Compress-Archive -Path (Join-Path $srcDir.FullName '*') -DestinationPath $zipPath

$hash = (Get-FileHash -Algorithm SHA256 $zipPath).Hash.ToLower()
"$hash  $outName.zip" | Out-File -Encoding ascii (Join-Path $OutputDir "$outName.zip.sha256")
Write-Host "==> sha256: $hash"
Write-Host "==> Done: $zipPath"
