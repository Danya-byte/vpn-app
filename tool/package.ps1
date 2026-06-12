<#
  package.ps1 - build + package a portable Windows release.

  Builds the release app with the version/commit stamped in (so About reports the
  exact build), bundles the SHA-256-verified cores + rule-sets + the license and
  third-party notices, and zips it to dist\. CorePaths resolves core\windows\ next
  to the executable, so the cores are copied beside vpn_app.exe inside the archive
  - extract-and-run, no installer.

  The release ships UNSIGNED, on purpose: this is open-source with public releases,
  so the published .sha256 is the integrity check (verify it against the release
  page). An Authenticode cert only suppresses the SmartScreen prompt - a UX nicety,
  not a security property - so we don't require one. (If you ever want it, sign the
  artifacts in dist\ yourself before uploading; nothing here depends on it.)

    pwsh tool\package.ps1
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

# --- version + commit stamp ---------------------------------------------------
# Prefer an explicit RELEASE_VERSION (CI sets it from the commit-message marker
# [vX.Y], so the build/installer/About match the published tag); else pubspec.
$pubspec = Get-Content (Join-Path $root 'pubspec.yaml') -Raw
$ver = if ($env:RELEASE_VERSION) { $env:RELEASE_VERSION.Trim() }
       elseif ($pubspec -match '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)') { $Matches[1] }
       else { '0.0.0' }
$sha = try { (& git -C $root rev-parse --short HEAD).Trim() } catch { 'nogit' }
Write-Host "Building VPN App $ver ($sha) ..."

# --- build with the stamp baked in --------------------------------------------
& flutter build windows --release `
  --dart-define "APP_VERSION=$ver" --dart-define "APP_BUILD=$sha"
if ($LASTEXITCODE -ne 0) { throw 'flutter build failed' }

$rel = Join-Path $root 'build\windows\x64\runner\Release'
if (-not (Test-Path (Join-Path $rel 'vpn_app.exe'))) {
  throw 'Release build not found'
}

# --- bundle the proxy cores + rule-sets beside the app ------------------------
$coreSrc = Join-Path $root 'core\windows'
# A RELEASE must ship the FULL core set: sing-box (tunnel), xray (XHTTP bridge),
# and the desync engine (winws + WinDivert driver + QUIC decoy) that powers the
# headline server-less DPI bypass. A missing winws.exe = a release whose flagship
# feature is permanently absent (the audit's #1 blocker), so guard all of them.
foreach ($c in @('sing-box.exe', 'xray.exe', 'winws.exe', 'WinDivert64.sys', 'quic_initial.bin')) {
  if (-not (Test-Path (Join-Path $coreSrc $c))) {
    throw "Release core '$c' missing - run: pwsh tool/fetch-cores.ps1 -IncludeXray -IncludeDesync"
  }
}
$coreDst = Join-Path $rel 'core\windows'
New-Item -ItemType Directory -Force -Path $coreDst | Out-Null
Copy-Item -Path (Join-Path $coreSrc '*') -Destination $coreDst -Recurse -Force

$rsSrc = Join-Path $root 'core\rule-sets'
if (Test-Path $rsSrc) {
  $rsDst = Join-Path $rel 'core\rule-sets'
  New-Item -ItemType Directory -Force -Path $rsDst | Out-Null
  Copy-Item -Path (Join-Path $rsSrc '*') -Destination $rsDst -Recurse -Force
}

# --- bundle license + third-party notices (GPL-3.0 distribution requirement) ---
$license = Join-Path $root 'LICENSE'
$notices = Join-Path $root 'THIRD_PARTY_NOTICES.md'
if (Test-Path $license) { Copy-Item $license (Join-Path $rel 'LICENSE.txt') -Force }
else { Write-Warning 'LICENSE missing - GPL-3.0 distribution requires it' }
if (Test-Path $notices) { Copy-Item $notices $rel -Force }
else { Write-Warning 'THIRD_PARTY_NOTICES.md missing' }
$copying = Join-Path $root 'COPYING'
if (-not (Test-Path $copying)) {
  # Fetch the verbatim GPL-3.0 text once so every release ships the full license.
  try {
    Invoke-WebRequest 'https://www.gnu.org/licenses/gpl-3.0.txt' -OutFile $copying
  } catch { Write-Warning "couldn't fetch COPYING (GPL text): $_" }
}
if (Test-Path $copying) { Copy-Item $copying (Join-Path $rel 'COPYING.txt') -Force }

# --- zip + publish the SHA-256 so users can verify the download ----------------
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$zip = Join-Path $dist 'vpn_app-windows-x64.zip'
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $rel '*') -DestinationPath $zip
$hash = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
Set-Content -Path "$zip.sha256" -Value "$hash  vpn_app-windows-x64.zip" -Encoding ascii

# --- optional installer (Inno Setup), built from the same populated Release ---
# Inno Setup often isn't on PATH (esp. the user-scope install under LOCALAPPDATA),
# so fall back to the standard install locations before giving up.
$isccPath = (Get-Command iscc.exe -ErrorAction SilentlyContinue).Source
if (-not $isccPath) {
  foreach ($p in @(
      "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
      "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
      "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe")) {
    if (Test-Path $p) { $isccPath = $p; break }
  }
}
if ($isccPath) {
  & $isccPath "/DAppVer=$ver" (Join-Path $PSScriptRoot 'installer.iss')
  if ($LASTEXITCODE -ne 0) { throw 'iscc (installer build) failed' }
  $setup = Join-Path $dist "vpn_app-setup-$ver.exe"
  if (Test-Path $setup) {
    $sh = (Get-FileHash -Algorithm SHA256 $setup).Hash.ToLowerInvariant()
    Set-Content -Path "$setup.sha256" -Value "$sh  vpn_app-setup-$ver.exe" -Encoding ascii
    Write-Output "Installer: $setup"
  }
} else {
  Write-Host 'iscc not found - skipping installer (install Inno Setup to build it)'
}

$mb = [math]::Round((Get-Item $zip).Length / 1MB, 1)
Write-Output "Packaged: $zip ($mb MB)"
Write-Output "SHA-256 : $hash"
