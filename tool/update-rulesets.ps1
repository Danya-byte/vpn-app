# Refresh the geo rule-set pins in fetch-cores.ps1 to the CURRENT upstream commit.
#
# WHY this exists: fetch-cores.ps1 pins the SagerNet geo .srs rule-sets to a FROZEN
# commit (not the rolling 'rule-set' branch) so the SHA-256 never drifts and the
# release build can't break out of nowhere when SagerNet rebuilds the data. When you
# WANT fresher geo data, run this: it reads each repo's rule-set-branch HEAD commit,
# downloads the files, computes their SHA-256, and (with -Apply) rewrites the pins.
#
#   pwsh tool/update-rulesets.ps1            # print the new commit + hashes to paste
#   pwsh tool/update-rulesets.ps1 -Apply     # also rewrite fetch-cores.ps1 in place
#
# It uses `git ls-remote` for the commit (no GitHub API rate limit) and downloads
# from the COMMIT url (immutable), so what it pins is exactly what it verified.

param([switch]$Apply)
$ErrorActionPreference = 'Stop'
$ua = @{ 'User-Agent' = 'vpn-app' }
$fetch = Join-Path $PSScriptRoot 'fetch-cores.ps1'

function HeadCommit($repo) {
  $line = (& git ls-remote "https://github.com/$repo" 'rule-set' | Select-Object -First 1)
  if (-not $line) { throw "could not read rule-set branch HEAD for $repo" }
  ($line -split "`t")[0].Trim()
}

function ShaOf($url) {
  $tmp = New-TemporaryFile
  try {
    Invoke-WebRequest -Headers $ua $url -OutFile $tmp
    if ((Get-Item $tmp).Length -lt 256) { throw "suspiciously small download from $url (404 / error page?)" }
    (Get-FileHash -Algorithm SHA256 $tmp).Hash.ToLowerInvariant()
  } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

$geoip   = HeadCommit 'SagerNet/sing-geoip'
$geosite = HeadCommit 'SagerNet/sing-geosite'

$items = @(
  @{ Name = 'geoip-ru.srs';    Url = "https://raw.githubusercontent.com/SagerNet/sing-geoip/$geoip/geoip-ru.srs" },
  @{ Name = 'geosite-ru.srs';  Url = "https://raw.githubusercontent.com/SagerNet/sing-geosite/$geosite/geosite-category-ru.srs" },
  @{ Name = 'geosite-ads.srs'; Url = "https://raw.githubusercontent.com/SagerNet/sing-geosite/$geosite/geosite-category-ads-all.srs" }
)
foreach ($it in $items) { $it.Sha = ShaOf $it.Url }

Write-Host "geoip   rule-set commit: $geoip"
Write-Host "geosite rule-set commit: $geosite"
foreach ($it in $items) { Write-Host ("  {0,-16} {1}" -f $it.Name, $it.Sha) }

if (-not $Apply) {
  Write-Host "`n(dry run) re-run with -Apply to rewrite the pins in fetch-cores.ps1"
  return
}

$txt = Get-Content $fetch -Raw
$txt = [regex]::Replace($txt, "(\`$geoipCommit\s*=\s*')[0-9a-f]{40}(')",   "`${1}$geoip`$2")
$txt = [regex]::Replace($txt, "(\`$geositeCommit\s*=\s*')[0-9a-f]{40}(')", "`${1}$geosite`$2")
foreach ($it in $items) {
  $pat = "(Name = '" + [regex]::Escape($it.Name) + "';.*?Sha = ')[0-9a-f]{64}(')"
  $txt = [regex]::Replace($txt, $pat, ("`${1}" + $it.Sha + "`$2"))
}
# Keep the file ASCII + no BOM (PowerShell 5.1 chokes on a BOM-less smart-quote, and
# Set-Content -Encoding utf8 would add a BOM); write plain ASCII bytes.
[System.IO.File]::WriteAllText($fetch, $txt, (New-Object System.Text.ASCIIEncoding))
Write-Host "`nfetch-cores.ps1 updated."
