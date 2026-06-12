# tg-ws-probe.ps1 (v3) - map every SERVER-LESS Telegram path on THIS network.
#
# v1 bug: DoH returned the record TYPE not the IP. v2 bug: PowerShell 5.1 rejects the
# cert on an IP-literal DoH URL (https://1.1.1.1/). The block here is IP-based, NOT
# DNS-based (your blockcheck resolved Telegram fine), so v3 just uses the SYSTEM
# resolver -- no DoH needed -- and a global cert-accept so TLS can't be the blocker.
#
# Tests three server-less hopes:
#   1. WSS-DIRECT to Telegram web endpoints (pluto/venus/aurora/vesta/flora) - tglock style.
#   2. CLOUDFLARE-EDGE reachability -> viability of a FREE Cloudflare Worker bridge
#      (wss -> Worker -> Telegram); survives a full TG-range blackhole since traffic
#      rides Cloudflare, which TSPU can't blackhole without breaking half the RU net.
#   3. IPv6 direct (TSPU's TG blackhole is often v4-only).
#
# Read-only. 5s timeouts. Dials only Telegram/Cloudflare public hostnames.

$ErrorActionPreference = 'SilentlyContinue'
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { param($a,$b,$c,$d) $true }
$timeoutMs = 5000
$acceptAll = [System.Net.Security.RemoteCertificateValidationCallback] { param($s,$c,$h,$e) return $true }
$ip4re = [regex]'^(?:\d{1,3}\.){3}\d{1,3}$'

function Resolve-Sys($name, $family) {
  # System DNS (operator resolver). Block is IP-based so this returns the real IPs.
  try {
    $addrs = [System.Net.Dns]::GetHostAddresses($name)
    $fam = [System.Net.Sockets.AddressFamily]::InterNetwork
    if ($family -eq 'v6') { $fam = [System.Net.Sockets.AddressFamily]::InterNetworkV6 }
    return ,@($addrs | Where-Object { $_.AddressFamily -eq $fam } | ForEach-Object { $_.IPAddressToString })
  } catch { return ,@() }
}

function Tag-Ip($ip) {
  if ($ip -match '^(149\.154\.|91\.108\.|95\.161\.|91\.105\.|185\.76\.)') { return 'TG-DC(blocked range)' }
  if ($ip -match '^(104\.1[6-9]\.|104\.2[0-7]\.|172\.6[4-9]\.|172\.7[01]\.|188\.114\.)') { return 'Cloudflare' }
  if ($ip -match '^(0\.|127\.|10\.|192\.168\.|169\.254\.)') { return 'SINKHOLE/stub?' }
  return 'other'
}

function Test-Tcp($ip, $port) {
  $c = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $c.BeginConnect($ip, $port, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne($timeoutMs)) { $c.Close(); return 'TIMEOUT' }
    $c.EndConnect($iar); $c.Close(); return 'OPEN'
  } catch { try { $c.Close() } catch {}; return 'RST/no-route' }
}

function Test-WssUpgrade($ip, $sni, $path) {
  $c = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $c.BeginConnect($ip, 443, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne($timeoutMs)) { $c.Close(); return 'tcp-TIMEOUT' }
    $c.EndConnect($iar)
    $c.ReceiveTimeout = $timeoutMs; $c.SendTimeout = $timeoutMs
    $ssl = New-Object System.Net.Security.SslStream($c.GetStream(), $false, $acceptAll)
    $ssl.AuthenticateAsClient($sni)
    $proto = $ssl.SslProtocol
    $key = [Convert]::ToBase64String((1..16 | ForEach-Object { [byte](Get-Random -Maximum 256) }))
    $nl = [char]13 + [char]10
    $req = "GET $path HTTP/1.1$nl" + "Host: $sni$nl" + "Upgrade: websocket$nl" +
           "Connection: Upgrade$nl" + "Sec-WebSocket-Key: $key$nl" +
           "Sec-WebSocket-Version: 13$nl" + "Sec-WebSocket-Protocol: binary$nl" +
           "Origin: https://web.telegram.org$nl$nl"
    $b = [System.Text.Encoding]::ASCII.GetBytes($req)
    $ssl.Write($b, 0, $b.Length); $ssl.Flush()
    Start-Sleep -Milliseconds 400
    $buf = New-Object byte[] 2048
    $n = $ssl.Read($buf, 0, $buf.Length)
    $resp = [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
    try { $ssl.Close() } catch {}; $c.Close()
    $line = (($resp -split [char]10)[0]).Trim()
    if ($resp -match ' 101 ') { return "WSS-101 OK [$proto] <$line>" }
    if ($line.Length -gt 0)   { return "TLS-OK [$proto], no 101 <$line>" }
    return "TLS-OK [$proto], no-response"
  } catch { try { $c.Close() } catch {}; return "tls/wss-FAIL" }
}

Write-Output "================== Telegram server-less path map (v3) =================="
Write-Output ("admin={0}   {1}" -f ([bool]([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)), (Get-Date))
Write-Output ("CONTROL 1.1.1.1:443 = {0}" -f (Test-Tcp '1.1.1.1' 443))
$probe = Resolve-Sys 'web.telegram.org' 'v4'
$dnsOk = ($probe.Count -gt 0 -and $ip4re.IsMatch([string]$probe[0]))
Write-Output ("DNS self-test: web.telegram.org -> [{0}]  {1}" -f ($probe -join ', '), $(if ($dnsOk) { 'OK' } else { 'BROKEN' }))
Write-Output ""

Write-Output "(1) WSS-DIRECT - Telegram web endpoints:"
$wssWin = $false
foreach ($h in @('pluto.web.telegram.org','venus.web.telegram.org','aurora.web.telegram.org','vesta.web.telegram.org','flora.web.telegram.org','kws1.web.telegram.org','kws3.web.telegram.org','zws1.web.telegram.org')) {
  $ips = Resolve-Sys $h 'v4'
  if ($ips.Count -eq 0 -or -not $ip4re.IsMatch([string]$ips[0])) { Write-Output ("  {0,-26} (resolve failed)" -f $h); continue }
  $ip = [string]$ips[0]; $tag = Tag-Ip $ip; $tcp = Test-Tcp $ip 443; $wss = '-'
  if ($tcp -eq 'OPEN') { $wss = Test-WssUpgrade $ip $h '/apiws'; if ($wss -like 'WSS-101*') { $wssWin = $true } }
  Write-Output ("  {0,-26} {1,-16} [{2,-20}] TCP={3,-12} {4}" -f $h, $ip, $tag, $tcp, $wss)
}
Write-Output ""

Write-Output "(2) CLOUDFLARE EDGE - viability of a FREE Worker bridge (wss -> Worker -> TG):"
$cfWin = $false
foreach ($h in @('workers.dev','cloudflare.com','discord.com','speed.cloudflare.com')) {
  $ips = Resolve-Sys $h 'v4'
  if ($ips.Count -eq 0 -or -not $ip4re.IsMatch([string]$ips[0])) { Write-Output ("  {0,-22} (resolve failed)" -f $h); continue }
  $ip = [string]$ips[0]; $tag = Tag-Ip $ip; $tcp = Test-Tcp $ip 443; $wss = '-'
  if ($tcp -eq 'OPEN') { $wss = Test-WssUpgrade $ip $h '/'; if ($wss -like 'WSS-101*' -or $wss -like 'TLS-OK*') { $cfWin = $true } }
  Write-Output ("  {0,-22} {1,-16} [{2,-12}] TCP={3,-12} {4}" -f $h, $ip, $tag, $tcp, $wss)
}
Write-Output ""

Write-Output "(3) IPv6 direct:"
$v6 = Test-Tcp '2606:4700:4700::1111' 443
Write-Output ("  Cloudflare v6 route = {0}" -f $v6)
if ($v6 -eq 'OPEN') {
  foreach ($t in @('2001:67c:4e8:f002::a','2001:b28:f23d:f001::a','2001:b28:f23f:f005::a')) {
    Write-Output ("  raw-DC v6 {0,-28} TCP={1}" -f $t, (Test-Tcp $t 443))
  }
}
Write-Output ""
Write-Output "========================== VERDICT =========================="
if (-not $dnsOk) {
  Write-Output "Even system DNS for web.telegram.org failed -> tell me; likely a deeper DNS issue."
} elseif ($wssWin) {
  Write-Output "WSS-101 on a Telegram web endpoint -> SERVER-LESS WSS-direct WORKS. Build MTProto->WSS bridge."
} elseif ($cfWin) {
  Write-Output "Telegram web is blackholed, BUT Cloudflare edge is reachable + TLS completes."
  Write-Output "=> FREE Cloudflare Worker bridge is viable: no VPS, no subscription, traffic rides"
  Write-Output "   Cloudflare (un-blackholable). The server-less answer for THIS hard-block net."
} elseif ($v6 -eq 'OPEN') {
  Write-Output "IPv6 route exists -> route Telegram over v6 (often server-less when TSPU is v4-only)."
} else {
  Write-Output "TG web blackholed AND Cloudflare edge unreachable AND no v6 -> this net needs a"
  Write-Output "foreign exit for Telegram. (If even Cloudflare is dead, the net is on a tight whitelist.)"
}
Write-Output "============================================================="
