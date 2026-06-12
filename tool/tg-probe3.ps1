# tg-probe3.ps1 - two server-less cracks from the invention workflow (pure PowerShell).
#
# (4) OFF-CIDR ENDPOINTS: the block is the PUBLISHED Telegram cidr.txt. Resolve Telegram's
#     whole domain surface and find any TG-owned IP that lives OUTSIDE that range -- even
#     one reachable bootstrap/CDN/media IP = a direct server-less route (MTProto auth is
#     IP-agnostic: any DC IP that answers works).
#
# (3) UDP PROTO-17 PROBE: the middlebox drops TCP to Telegram but ICMP passes. Is UDP also
#     dropped, or only TCP? Trick: a CONNECTED UDP socket that receives an ICMP port-unreach
#     surfaces it as a 'ConnectionReset' exception -> that means the datagram REACHED the
#     host. So: REPLY or ConnectionReset from a Telegram IP = UDP PASSES the filter (keystone
#     for UDP transports). Timeout = dropped/silent. A control to 1.1.1.1:9 calibrates whether
#     the ICMP-unreach channel works on this network at all.
#
# Read-only measurement. No admin needed. ~4s timeouts.

$ErrorActionPreference = 'SilentlyContinue'
$blockedRe = '^(149\.154\.|91\.108\.|95\.161\.|91\.105\.|185\.76\.)'
$ip4re = [regex]'^(?:\d{1,3}\.){3}\d{1,3}$'

function Resolve-Sys($name) {
  try {
    return @([System.Net.Dns]::GetHostAddresses($name) |
      Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString })
  } catch { return @() }
}
function Test-Tcp($ip, $port) {
  $c = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $c.BeginConnect($ip, $port, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne(4000)) { $c.Close(); return 'TIMEOUT' }
    $c.EndConnect($iar); $c.Close(); return 'OPEN!!'
  } catch {
    try { $c.Close() } catch {}
    if ($_.Exception.InnerException.SocketErrorCode -eq 'ConnectionRefused') { return 'RST(reachable!)' }
    return 'RST/err'
  }
}
function Test-Udp($ip, $port, $ms) {
  $u = New-Object System.Net.Sockets.UdpClient
  try {
    $u.Client.ReceiveTimeout = $ms
    $u.Connect($ip, $port)
    $pl = New-Object byte[] 32
    [void]$u.Send($pl, $pl.Length)
    $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
    $r = $u.Receive([ref]$ep)
    return "REPLY($($r.Length)b)"
  } catch [System.Net.Sockets.SocketException] {
    $code = $_.Exception.SocketErrorCode
    if ($code -eq 'ConnectionReset') { return 'REACHED(unreach)' }
    if ($code -eq 'TimedOut') { return 'dropped/silent' }
    return "err:$code"
  } catch { return 'err' }
  finally { try { $u.Close() } catch {} }
}

Write-Output "==================== tg-probe3 (server-less cracks) ===================="
Write-Output ("CONTROL 1.1.1.1:443 tcp = {0}" -f (Test-Tcp '1.1.1.1' 443))
Write-Output ""

# --- (4) off-CIDR Telegram endpoint sweep ---
Write-Output "(4) Telegram endpoints OUTSIDE the blocked CIDR (any OPEN/RST = direct route!):"
$domains = @(
  'telegram.org','www.telegram.org','core.telegram.org','web.telegram.org','my.telegram.org',
  'desktop.telegram.org','instantview.telegram.org','promote.telegram.org','tdesktop.com',
  't.me','telegram.me','telegram.dog','telegra.ph','comments.app','fragment.com',
  'cdn-telegram.org','cdn1-telegram.org','cdn4.telegram-cdn.org','cdn5.telegram-cdn.org',
  'stel.com','apv1.stel.com','apv2.stel.com','apv3.stel.com','telesco.pe',
  'venus.web.telegram.org','pluto.web.telegram.org'
)
$seen = @{}
$offcidr = @()
foreach ($d in $domains) {
  foreach ($ip in (Resolve-Sys $d)) {
    if (-not $ip4re.IsMatch($ip)) { continue }
    if ($seen.ContainsKey($ip)) { continue }
    $seen[$ip] = $true
    $inBlocked = $ip -match $blockedRe
    if ($inBlocked) { continue }   # in-CIDR = already known blackholed; skip
    $r = Test-Tcp $ip 443
    $offcidr += [pscustomobject]@{ d = $d; ip = $ip; r = $r }
  }
}
if ($offcidr.Count -eq 0) {
  Write-Output "  every resolved Telegram IP is INSIDE the blocked CIDR (no off-CIDR endpoint)."
} else {
  foreach ($o in $offcidr) {
    $fg = if ($o.r -like 'OPEN*' -or $o.r -like 'RST(*') { 'Green' } else { 'Gray' }
    Write-Host ("  {0,-26} {1,-16} {2}" -f $o.d, $o.ip, $o.r) -ForegroundColor $fg
  }
  $win = $offcidr | Where-Object { $_.r -like 'OPEN*' -or $_.r -like 'RST(*' }
  if ($win) { Write-Output "  ^ REACHABLE Telegram-owned IPs outside the block exist -- worth a direct MTProto try." }
}
Write-Output ""

# --- (3) UDP proto-17 probe ---
Write-Output "(3) UDP to Telegram -- is the filter TCP-only? (REACHED/REPLY = UDP passes):"
$ctrl = Test-Udp '1.1.1.1' 9 3000
Write-Output ("  CONTROL 1.1.1.1:9 udp = {0}  {1}" -f $ctrl, $(if ($ctrl -eq 'REACHED(unreach)') { '(unreach channel works -> probe is meaningful)' } else { '(unreach suppressed -> UDP result may be inconclusive)' }))
$udpIps = @('149.154.167.51','149.154.175.50','91.108.56.130','95.161.64.5')
$udpPorts = @(443,500,4500,3478,53,599)
$udpHit = $false
foreach ($ip in $udpIps) {
  $line = "  $ip : "
  foreach ($p in $udpPorts) {
    $r = Test-Udp $ip $p 2500
    if ($r -eq 'REACHED(unreach)' -or $r -like 'REPLY*') { $udpHit = $true; $line += "$p=$r " }
  }
  if ($line.Trim() -ne "$ip :") { Write-Host $line -ForegroundColor Green } else { Write-Output "$line(all dropped/silent)" }
}
Write-Output ""
Write-Output "========================== VERDICT =========================="
if ($win) {
  Write-Output "(4) CRACK: a reachable Telegram IP outside the blocked CIDR exists -> direct server-less"
  Write-Output "    MTProto is on the table. I build a client that pins that IP."
} elseif ($udpHit) {
  Write-Output "(3) UDP PASSES the Telegram filter (TCP-only block) -> new family open: WireGuard/QUIC"
  Write-Output "    masquerade straight to a Telegram IP, or UDP-based transport. I build that."
} else {
  Write-Output "Both closed here: every TG IP in-CIDR + TCP-blocked, and UDP dropped too. The filter"
  Write-Output "is proto-agnostic dst-IP. Then the only pure-packet shot left is WinDivert source-route"
  Write-Output "decoy (low odds) -- tell me and I write the custom injector; else an intermediate is needed."
}
Write-Output "============================================================="
