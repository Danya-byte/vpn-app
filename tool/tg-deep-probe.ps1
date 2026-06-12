# tg-deep-probe.ps1 - dig for a server-less crack in the Telegram block.
#
# Answers two questions the simple blockcheck didn't:
#   (1) Is the WHOLE Telegram CIDR dead, or only the well-known DCs? A live IP anywhere
#       in the range = a server-less route.
#   (2) Is the drop a dumb null-route, or a middlebox that kills only TCP-to-Telegram?
#       If ICMP (tracert) reaches Telegram while TCP times out, it's a stateful box that
#       can sometimes be desynced (that's where the real tricks live). If tracert also
#       dies at the operator hop, it's a null-route -> no local trick can help.
#
# Read-only. ~4s TCP timeouts. Admin not required for the probe.

$ErrorActionPreference = 'SilentlyContinue'
$timeoutMs = 4000

function Test-Tcp($ip, $port) {
  $c = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $c.BeginConnect($ip, $port, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne($timeoutMs)) { $c.Close(); return 'TIMEOUT' }
    $c.EndConnect($iar); $c.Close(); return 'OPEN'
  } catch {
    try { $c.Close() } catch {}
    # connection refused (RST) means the IP is REACHABLE (routing works), port closed.
    if ($_.Exception.InnerException -and $_.Exception.InnerException.SocketErrorCode -eq 'ConnectionRefused') { return 'RST(reachable!)' }
    return 'RST/err'
  }
}

Write-Output "==================== Telegram deep probe ===================="
Write-Output ("CONTROL 1.1.1.1:443 = {0}" -f (Test-Tcp '1.1.1.1' 443))
Write-Output ""

# --- (1) full-CIDR sweep: sample many IPs across EVERY published Telegram range ---
Write-Output "(1) CIDR sweep (any line NOT 'TIMEOUT' = a reachable Telegram IP = a crack):"
$ips = @(
  '91.108.4.5','91.108.5.100','91.108.6.200','91.108.7.250',
  '91.108.8.5','91.108.9.100','91.108.10.200',
  '91.108.12.5','91.108.13.100','91.108.14.200',
  '91.108.16.5','91.108.17.100','91.108.18.200',
  '91.108.20.5','91.108.21.100','91.108.22.200',
  '91.108.56.5','91.108.57.100','91.108.58.200',
  '95.161.64.5','95.161.68.100','95.161.72.200','95.161.79.250',
  '149.154.160.5','149.154.163.100','149.154.167.99','149.154.170.96','149.154.175.200',
  '185.76.151.5','185.76.151.100','185.76.151.200',
  '91.105.192.5','91.105.193.100'
)
$crack = @()
foreach ($ip in $ips) {
  $r = Test-Tcp $ip 443
  if ($r -ne 'TIMEOUT') { $crack += "$ip -> $r" }
}
if ($crack.Count -gt 0) {
  Write-Output "  CRACK FOUND -- reachable Telegram IPs:"
  $crack | ForEach-Object { Write-Output "    $_" }
} else {
  Write-Output "  all $($ips.Count) sampled IPs across every Telegram range: TIMEOUT (whole-range blackhole)."
}
Write-Output ""

# --- (2) alternate ports on two known DCs (is it whole-IP or per-port?) ---
Write-Output "(2) Alternate ports on Telegram DCs (any OPEN/RST = the block is per-port, not per-IP):"
foreach ($ip in @('149.154.167.51','91.108.56.130')) {
  foreach ($p in @(443,80,5222,2087,8443,993,587,2083)) {
    $r = Test-Tcp $ip $p
    if ($r -ne 'TIMEOUT') { Write-Output ("    {0}:{1} -> {2}" -f $ip,$p,$r) }
  }
}
Write-Output "  (only non-TIMEOUT ports are printed; nothing below this line = all dead)"
Write-Output ""

# --- (3) tracert: where + how do packets die? (null-route vs TCP-only middlebox) ---
Write-Output "(3) Traceroute (ICMP) -- compare a working IP vs Telegram. KEY signal:"
Write-Output "    if Telegram tracert REACHES the target (or goes much further than the TCP"
Write-Output "    drop), ICMP passes where TCP is killed -> a TCP middlebox (maybe desyncable)."
Write-Output ""
Write-Output "  --- tracert 1.1.1.1 (control) ---"
& tracert -d -h 15 -w 700 1.1.1.1 | Select-Object -Skip 2 | ForEach-Object { Write-Output "  $_" }
Write-Output ""
Write-Output "  --- tracert 149.154.167.51 (Telegram DC2) ---"
& tracert -d -h 20 -w 700 149.154.167.51 | Select-Object -Skip 2 | ForEach-Object { Write-Output "  $_" }
Write-Output ""
Write-Output "==================== READ ME ===================="
Write-Output "Send the whole output. I'm looking for: (1) any reachable IP/port = instant"
Write-Output "server-less route; (3) whether ICMP reaches Telegram (TCP middlebox -> desync"
Write-Output "tricks possible) or dies at your operator hop (null-route -> intermediate required)."
Write-Output "================================================="
