# tg-asn-sweep.ps1 - find a reachable Telegram IP OUTSIDE the published cidr.txt block.
#
# The middlebox blocks the published Telegram cidr.txt. But Telegram's ASNs announce ALL
# their routed space, which can include prefixes NOT in cidr.txt (and possibly not in the
# block-list). MTProto auth is IP-agnostic: ANY DC IP that answers a TCP :443 is usable.
# So: pull every prefix announced by Telegram's ASNs from RIPE stat (reachable), and TCP-
# test sample IPs of the ones OUTSIDE the known-blocked ranges. Any OPEN = a direct route.
#
# Read-only, no admin. Pure PowerShell.

$ErrorActionPreference = 'SilentlyContinue'
$blockedRe = '^(149\.154\.|91\.108\.|95\.161\.|91\.105\.|185\.76\.)'

function Test-Tcp($ip, $port) {
  $c = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $c.BeginConnect($ip, $port, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne(3000)) { $c.Close(); return 'TIMEOUT' }
    $c.EndConnect($iar); $c.Close(); return 'OPEN!!'
  } catch { try { $c.Close() } catch {}; if ($_.Exception.InnerException.SocketErrorCode -eq 'ConnectionRefused') { return 'RST(reachable!)' }; return 'RST/err' }
}
function SampleIps($cidr) {
  $parts = $cidr -split '/'; if ($parts.Count -ne 2) { return @() }
  $b = ([System.Net.IPAddress]::Parse($parts[0])).GetAddressBytes()
  $base = [uint32](([uint32]$b[0] -shl 24) -bor ([uint32]$b[1] -shl 16) -bor ([uint32]$b[2] -shl 8) -bor $b[3])
  $out = @()
  foreach ($off in @(1, 5, 100, 130)) {
    $v = $base + $off
    $out += ("{0}.{1}.{2}.{3}" -f (($v -shr 24) -band 0xFF), (($v -shr 16) -band 0xFF), (($v -shr 8) -band 0xFF), ($v -band 0xFF))
  }
  return $out
}

Write-Output "==================== Telegram ASN sweep ===================="
$asns = @('AS62041', 'AS62014', 'AS59930', 'AS44907', 'AS211157')
$prefixes = @{}
foreach ($as in $asns) {
  try {
    $r = Invoke-RestMethod -Uri "https://stat.ripe.net/data/announced-prefixes/data.json?resource=$as" -TimeoutSec 20
    foreach ($p in $r.data.prefixes) { if ($p.prefix -and $p.prefix -notmatch ':') { $prefixes[$p.prefix] = $as } }
    Write-Output ("  {0}: {1} v4 prefixes announced" -f $as, (@($r.data.prefixes | Where-Object { $_.prefix -notmatch ':' }).Count))
  } catch { Write-Output ("  {0}: RIPE fetch failed ({1})" -f $as, $_.Exception.Message) }
}
Write-Output ""
if ($prefixes.Count -eq 0) { Write-Output "No prefixes fetched (RIPE stat unreachable?). Tell me; I'll hardcode a list."; exit 0 }

$offCidr = @($prefixes.Keys | Where-Object { $_ -notmatch $blockedRe })
$inCidr  = @($prefixes.Keys | Where-Object { $_ -match $blockedRe })
Write-Output ("Prefixes: {0} total, {1} inside the known block, {2} OUTSIDE (the interesting ones):" -f $prefixes.Count, $inCidr.Count, $offCidr.Count)
Write-Output ""
$hits = @()
foreach ($pfx in ($offCidr | Sort-Object)) {
  foreach ($ip in (SampleIps $pfx)) {
    $r = Test-Tcp $ip 443
    if ($r -ne 'TIMEOUT' -and $r -ne 'RST/err') { $hits += "$pfx  $ip -> $r" }
  }
}
if ($hits.Count) {
  Write-Output "REACHABLE Telegram-ASN IPs OUTSIDE the block (worth a direct MTProto try!):"
  $hits | ForEach-Object { Write-Host "  $_" -ForegroundColor Green }
} else {
  Write-Output "All off-CIDR Telegram-ASN sample IPs: TIMEOUT (the block covers the full ASN space here)."
}
Write-Output ""
Write-Output "off-CIDR prefixes tested:"
$offCidr | Sort-Object | ForEach-Object { Write-Output ("  {0}  [{1}]" -f $_, $prefixes[$_]) }
Write-Output ""
Write-Output "========================== VERDICT =========================="
if ($hits.Count) { Write-Output "CRACK candidate: a Telegram IP outside cidr.txt answered -> I build a client that pins it." }
else { Write-Output "No off-CIDR reachable Telegram IP. The block tracks the whole ASN, not just cidr.txt." }
Write-Output "============================================================="
