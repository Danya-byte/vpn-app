<#
  fetch-cores.ps1 - populates core\windows\ with proxy core binaries.

    sing-box.exe  master engine (TUN / routing / DNS / Clash API)
    wintun.dll    Windows TUN driver, required by sing-box TUN inbound
    xray.exe      sub-engine for transports sing-box lacks (XHTTP/SplitHTTP/mKCP)

  These binaries are git-ignored (large, redistributable). Run this to (re)populate:
    pwsh tool\fetch-cores.ps1            # sing-box + wintun + rule-sets
    pwsh tool\fetch-cores.ps1 -IncludeXray

  SUPPLY-CHAIN: the binaries are pinned to an exact version AND verified against a
  known SHA-256 (the exact bytes that pass `tool/verify_store.dart` and carry
  traffic). A poisoned mirror / MITM that swaps the binary makes this script FAIL
  HARD instead of silently shipping a backdoored core to users. To bump a core:
  update the version + paste the new hash below (compute it with `Get-FileHash`).
#>
[CmdletBinding()]
param(
  [string]$Dest = (Join-Path $PSScriptRoot '..\core\windows'),
  [switch]$IncludeXray
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
# Hash-pinned like the binaries. They DO update upstream - bumping one is a
# deliberate, tested change: re-paste the new SHA-256 here when you update it.
$rsDir = Join-Path (Split-Path $Dest -Parent) 'rule-sets'
New-Item -ItemType Directory -Force $rsDir | Out-Null
$ruleSets = @(
  @{ Name = 'geoip-ru.srs';    Url = 'https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs';                 Sha = '133d045108290b7e1ea929e3021807ad1842876d959bfc5ae347fdc7db4b5865' },
  @{ Name = 'geosite-ru.srs';  Url = 'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ru.srs';     Sha = '1996ce05d6b5a4d4a073be48e6f8ebec4efdddde49be32ac3f79018a80309367' },
  @{ Name = 'geosite-ads.srs'; Url = 'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs'; Sha = 'c35ecb467bc8029b68bf3b6a680a7ba66b0daf4fe9203f2104b6837fe1b8120e' }
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

Write-Host "`nCores in $Dest :"
Get-ChildItem $Dest | Select-Object Name, @{ n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } }
