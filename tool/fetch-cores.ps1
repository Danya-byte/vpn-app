<#
  fetch-cores.ps1 - populates core\windows\ with proxy core binaries.

    sing-box.exe  master engine (TUN / routing / DNS / Clash API)
    wintun.dll    Windows TUN driver, required by sing-box TUN inbound
    xray.exe      sub-engine for transports sing-box lacks (XHTTP/SplitHTTP/mKCP)
    winws.exe     zapret WinDivert desync sidecar - server-less TLS-DPI bypass
                  (+ cygwin1.dll, WinDivert.dll, WinDivert64.sys runtime files)

  These binaries are git-ignored (large, redistributable). Run this to (re)populate:
    pwsh tool\fetch-cores.ps1            # sing-box + wintun + rule-sets
    pwsh tool\fetch-cores.ps1 -IncludeXray -IncludeDesync

  SUPPLY-CHAIN: the binaries are pinned to an exact version AND verified against a
  known SHA-256 (the exact bytes that pass `tool/verify_store.dart` and carry
  traffic). A poisoned mirror / MITM that swaps the binary makes this script FAIL
  HARD instead of silently shipping a backdoored core to users. To bump a core:
  update the version + paste the new hash below (compute it with `Get-FileHash`).
#>
[CmdletBinding()]
param(
  [string]$Dest = (Join-Path $PSScriptRoot '..\core\windows'),
  [switch]$IncludeXray,
  [switch]$IncludeDesync
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ua = @{ 'User-Agent' = 'vpn-app-setup' }
$Dest = [System.IO.Path]::GetFullPath($Dest)
New-Item -ItemType Directory -Force $Dest | Out-Null

# --- pinned versions + expected SHA-256 of the EXTRACTED binary ---------------
$SingBox = @{
  Ver  = 'v1.13.12'
  Repo = 'SagerNet/sing-box'
  Zip  = 'sing-box-1.13.12-windows-amd64.zip'
  Exe  = 'sing-box.exe'
  Sha  = '64b1dfaed6fa758295233fd0bec8b32cf2115f29773adbf38e0f026c3c7986f2'
}
$Xray = @{
  Ver  = 'v26.3.27'
  Repo = 'XTLS/Xray-core'
  Zip  = 'Xray-windows-64.zip'
  Exe  = 'xray.exe'
  Sha  = '15c2d007954ac53ba69b80ec91242786b3c0b71d52649165b4ca1d5cc96ef8f1'
}
$Wintun = @{
  Url = 'https://www.wintun.net/builds/wintun-0.14.1.zip'
  Dll = 'wintun.dll'
  Sha = 'e5da8447dc2c320edc0fc52fa01885c103de8c118481f683643cacc3220dafce'
}
# zapret winws.exe (WinDivert) - the server-less TLS-DPI desync sidecar. The
# winws build is CYGWIN, so cygwin1.dll ships beside it; WinDivert.dll loads
# WinDivert64.sys (the kernel driver) from its own directory. All four go in
# core\windows. Pinned to a FROZEN release tag, so these hashes never drift.
$Desync = @{
  Ver   = 'v72.12'
  Repo  = 'bol-van/zapret'
  Zip   = 'zapret-v72.12.zip'
  Sub   = 'windows-x86_64' # NOT windows-x86 (identical filenames live there too)
  Files = @(
    @{ Name = 'winws.exe';       Sha = '2da71e80878dc270ac83f5893ecbb841f9752a57f1da8ff9325636b4346bc632' },
    @{ Name = 'cygwin1.dll';     Sha = '103104a52e5293ce418944725df19e2bf81ad9269b9a120d71d39028e821499b' },
    @{ Name = 'WinDivert.dll';   Sha = 'c1e060ee19444a259b2162f8af0f3fe8c4428a1c6f694dce20de194ac8d7d9a2' },
    @{ Name = 'WinDivert64.sys'; Sha = '8da085332782708d8767bcace5327a6ec7283c17cfb85e40b03cd2323a90ddc2' }
  )
  # fake-QUIC Initial decoy for the UDP/443 (HTTP-3) desync block. Lives under
  # files/fake/ in the zip (NOT windows-x86_64); installed as quic_initial.bin.
  QuicSrc = 'quic_initial_www_google_com.bin'
  QuicDst = 'quic_initial.bin'
  QuicSha = 'f4589c57749f956bb30538197a521d7005f8b0a8723b4707e72405e51ddac50a'
}

function Fetch($url, $name) {
  $p = Join-Path $env:TEMP $name
  Invoke-WebRequest -Headers $ua $url -OutFile $p
  $p
}
function Expand-Temp($zip, $tag) {
  $out = Join-Path $env:TEMP "core_$tag"
  Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue
  Expand-Archive $zip $out -Force
  $out
}
# Copy [src] -> [Dest\name] only if its SHA-256 matches the pin; else FAIL HARD.
function Install-Verified($srcPath, $name, $expectedSha) {
  $got = (Get-FileHash -Algorithm SHA256 $srcPath).Hash.ToLowerInvariant()
  if ($got -ne $expectedSha.ToLowerInvariant()) {
    throw "SHA-256 MISMATCH for $name`n  expected $expectedSha`n  got      $got`n" +
          "Refusing to install an unverified binary (possible tampered mirror)."
  }
  Copy-Item $srcPath (Join-Path $Dest $name) -Force
  Write-Host "$name  OK (sha256 verified)"
}
# Download a pinned GitHub release asset by exact tag (not 'latest').
function Get-PinnedAsset($repo, $tag, $zipName) {
  $rel = Invoke-RestMethod -Headers $ua "https://api.github.com/repos/$repo/releases/tags/$tag"
  $asset = $rel.assets | Where-Object { $_.name -eq $zipName } | Select-Object -First 1
  if (-not $asset) { throw "asset '$zipName' not found in $repo $tag" }
  $asset.browser_download_url
}

# --- sing-box (master) ---
$sbZip = Fetch (Get-PinnedAsset $SingBox.Repo $SingBox.Ver $SingBox.Zip) $SingBox.Zip
$sbDir = Expand-Temp $sbZip 'sb'
$sbExe = (Get-ChildItem -Recurse $sbDir -Filter $SingBox.Exe | Select-Object -First 1).FullName
Install-Verified $sbExe $SingBox.Exe $SingBox.Sha
Write-Host "sing-box $($SingBox.Ver)"

# --- wintun (TUN driver, HTTPS) ---
$wtZip = Fetch $Wintun.Url 'wintun.zip'
$wtDir = Expand-Temp $wtZip 'wt'
$wtDll = (Get-ChildItem -Recurse $wtDir -Filter $Wintun.Dll | Where-Object { $_.FullName -match '[\\/]amd64[\\/]wintun\.dll$' } | Select-Object -First 1).FullName
Install-Verified $wtDll $Wintun.Dll $Wintun.Sha

# --- rule-sets (routing data: control direct-vs-proxy, so tampering = a LEAK) ---
# Pinned to a FROZEN upstream COMMIT, NOT the rolling 'rule-set' branch HEAD: that
# branch is rebuilt periodically, which silently drifted the SHA-256 and broke the
# release build out of nowhere (the recurring "update the pin" failure). A commit's
# bytes are immutable, so these hashes NEVER drift and CI can't break on an upstream
# rebuild. To REFRESH the geo data later, bump BOTH the *Commit var and the Sha here
# (run tool/update-rulesets.ps1 to print the new values) - a deliberate, non-breaking
# change; the build still fails ONLY if a pinned commit's bytes don't match = real
# tampering.
$rsDir = Join-Path (Split-Path $Dest -Parent) 'rule-sets'
New-Item -ItemType Directory -Force $rsDir | Out-Null
$geoipCommit   = 'a508a0a09d30111e0ab5a0d9a3de1aff832d72b4'  # SagerNet/sing-geoip   rule-set branch
$geositeCommit = '6c9bd3e3634c5ca4653c3c9024d3f5712b12c796'  # SagerNet/sing-geosite rule-set branch
$ruleSets = @(
  @{ Name = 'geoip-ru.srs';    Url = "https://raw.githubusercontent.com/SagerNet/sing-geoip/$geoipCommit/geoip-ru.srs";                 Sha = '8bc18433e5d5b0644ba2a9ff74cd03428ba4f4e388b3c409f182de930e3c3170' },
  @{ Name = 'geosite-ru.srs';  Url = "https://raw.githubusercontent.com/SagerNet/sing-geosite/$geositeCommit/geosite-category-ru.srs";     Sha = '6b49430738116dcfb7b55a5ef1aef937e2af518cf87c06b4bf2987ab156bf017' },
  @{ Name = 'geosite-ads.srs'; Url = "https://raw.githubusercontent.com/SagerNet/sing-geosite/$geositeCommit/geosite-category-ads-all.srs"; Sha = 'd5ae1d63493f80067fdce35d4aac2edbb3d265acb9c3883411587f34c659d11d' }
)
foreach ($rs in $ruleSets) {
  $out = Join-Path $rsDir $rs.Name
  Invoke-WebRequest -Headers $ua $rs.Url -OutFile $out
  $got = (Get-FileHash -Algorithm SHA256 $out).Hash.ToLowerInvariant()
  if ($got -ne $rs.Sha.ToLowerInvariant()) {
    throw "SHA-256 MISMATCH for $($rs.Name)`n  expected $($rs.Sha)`n  got      $got`n" +
          "If you intentionally bumped the rule-set, update its pinned hash."
  }
  Write-Host "$($rs.Name)  OK (sha256 verified)"
}

# --- xray-core (sub-engine) ---
if ($IncludeXray) {
  $xrZip = Fetch (Get-PinnedAsset $Xray.Repo $Xray.Ver $Xray.Zip) $Xray.Zip
  $xrDir = Expand-Temp $xrZip 'xr'
  $xrExe = (Get-ChildItem -Recurse $xrDir -Filter $Xray.Exe | Select-Object -First 1).FullName
  Install-Verified $xrExe $Xray.Exe $Xray.Sha
  Write-Host "xray-core $($Xray.Ver)"
} else {
  Write-Host "xray-core skipped (pass -IncludeXray to fetch)"
}

# --- zapret winws (server-less TLS-DPI desync sidecar) ---
if ($IncludeDesync) {
  $dsZip = Fetch (Get-PinnedAsset $Desync.Repo $Desync.Ver $Desync.Zip) $Desync.Zip
  $dsDir = Expand-Temp $dsZip 'ds'
  foreach ($f in $Desync.Files) {
    $src = (Get-ChildItem -Recurse $dsDir -Filter $f.Name |
      Where-Object { $_.FullName -match [regex]::Escape($Desync.Sub) } |
      Select-Object -First 1).FullName
    if (-not $src) { throw "zapret: $($f.Name) not found under $($Desync.Sub)" }
    Install-Verified $src $f.Name $f.Sha
  }
  # fake-QUIC Initial decoy (files/fake/) -> quic_initial.bin
  $qsrc = (Get-ChildItem -Recurse $dsDir -Filter $Desync.QuicSrc |
    Select-Object -First 1).FullName
  if (-not $qsrc) { throw "zapret: $($Desync.QuicSrc) not found" }
  Install-Verified $qsrc $Desync.QuicDst $Desync.QuicSha
  Write-Host "zapret winws $($Desync.Ver)"
} else {
  Write-Host "zapret winws skipped (pass -IncludeDesync to fetch)"
}

Write-Host "`nCores in $Dest :"
Get-ChildItem $Dest | Select-Object Name, @{ n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } }
