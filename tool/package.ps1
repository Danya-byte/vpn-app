<#
  package.ps1 — build + package a portable Windows release.

  Builds the release app with the version/commit stamped in (so About reports the
  exact build), bundles the SHA-256-verified cores + rule-sets + the license and
  third-party notices, OPTIONALLY Authenticode-signs every binary, and zips it to
  dist\. CorePaths resolves core\windows\ next to the executable, so the cores are
  copied beside vpn_app.exe inside the archive — extract-and-run, no installer.

    pwsh tool\package.ps1
    # to sign (clears SmartScreen + reduces AV false-positives — critical for RF
    # users who sideload from Telegram), set these first:
    #   $env:VPNAPP_SIGN_PFX  = 'C:\path\to\cert.pfx'
    #   $env:VPNAPP_SIGN_PASS = '<pfx password>'
    # Pass -RequireSigning in CI to FAIL (not just warn) if the cert is missing.
#>
[CmdletBinding()]
param([switch]$RequireSigning)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

# --- version + commit stamp ---------------------------------------------------
$pubspec = Get-Content (Join-Path $root 'pubspec.yaml') -Raw
$ver = if ($pubspec -match '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)') { $Matches[1] } else { '0.0.0' }
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
if (-not (Test-Path (Join-Path $coreSrc 'sing-box.exe'))) {
  throw 'Cores not found - run: pwsh tool/fetch-cores.ps1 -IncludeXray'
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
else { Write-Warning 'LICENSE missing — GPL-3.0 distribution requires it' }
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

# --- optional Authenticode signing (E1) ---------------------------------------
function Find-SignTool {
  $c = Get-Command signtool.exe -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  $kits = 'C:\Program Files (x86)\Windows Kits\10\bin'
  if (Test-Path $kits) {
    $st = Get-ChildItem $kits -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -match 'x64' } | Select-Object -Last 1
    if ($st) { return $st.FullName }
  }
  return $null
}
$script:signtool = $null
function Sign-One($path) {
  if (-not (Test-Path $path)) { return }
  if (-not $script:signtool) {
    $script:signtool = Find-SignTool
    if (-not $script:signtool) { throw 'VPNAPP_SIGN_PFX set but signtool.exe not found (install the Windows SDK)' }
  }
  & $script:signtool sign /fd SHA256 /f $env:VPNAPP_SIGN_PFX /p $env:VPNAPP_SIGN_PASS `
    /tr http://timestamp.digicert.com /td SHA256 $path
  if ($LASTEXITCODE -ne 0) { throw "signing failed for $path" }
  Write-Host "signed: $(Split-Path $path -Leaf)"
}
$doSign = [bool]$env:VPNAPP_SIGN_PFX
if ($doSign) {
  Sign-One (Join-Path $rel 'vpn_app.exe')
  Sign-One (Join-Path $coreDst 'sing-box.exe')
  Sign-One (Join-Path $coreDst 'xray.exe')
} else {
  $msg = 'UNSIGNED build. SmartScreen will warn + AV may quarantine the cores. Set VPNAPP_SIGN_PFX to sign.'
  if ($RequireSigning) { throw $msg }
  Write-Warning $msg
}

# --- zip + publish the SHA-256 so users can verify the download ----------------
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$zip = Join-Path $dist 'vpn_app-windows-x64.zip'
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $rel '*') -DestinationPath $zip
$hash = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
Set-Content -Path "$zip.sha256" -Value "$hash  vpn_app-windows-x64.zip" -Encoding ascii

# --- optional installer (Inno Setup), built from the same populated Release ---
$iscc = Get-Command iscc.exe -ErrorAction SilentlyContinue
if ($iscc) {
  & $iscc.Source "/DAppVer=$ver" (Join-Path $PSScriptRoot 'installer.iss')
  if ($LASTEXITCODE -ne 0) { throw 'iscc (installer build) failed' }
  $setup = Join-Path $dist "vpn_app-setup-$ver.exe"
  if ($doSign) { Sign-One $setup }   # the installer itself must be signed too
  if (Test-Path $setup) {
    $sh = (Get-FileHash -Algorithm SHA256 $setup).Hash.ToLowerInvariant()
    Set-Content -Path "$setup.sha256" -Value "$sh  vpn_app-setup-$ver.exe" -Encoding ascii
    Write-Output "Installer: $setup"
  }
} else {
  Write-Host 'iscc not found — skipping installer (install Inno Setup to build it)'
}

$mb = [math]::Round((Get-Item $zip).Length / 1MB, 1)
Write-Output "Packaged: $zip ($mb MB)"
Write-Output "SHA-256 : $hash"
