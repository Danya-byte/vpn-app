<#
  telegram-blockcheck.ps1 -- map EXACTLY how Telegram is blocked on YOUR network,
  to decide whether a SERVER-LESS (admin / WinDivert / local-route) bypass is even
  physically possible, or whether a foreign exit server is unavoidable.

  For each Telegram datacenter IP (v4 AND v6) it does a RAW TCP connect (direct,
  ignores any proxy) and classifies the result:

    OPEN     - TCP connected. The IP is reachable. MTProto authenticates by crypto,
               NOT by IP, so ANY reachable Telegram IP is usable -> a local redirect
               to a live IP works WITHOUT a server.
    RST      - the host reset / refused us. The IP is REACHABLE (not blackholed);
               the port is closed OR DPI is injecting a reset -> a winws anti-RST
               pass MIGHT save it, server-less (auto-tested at the end).
    TIMEOUT  - no answer to the SYN = the IP/range is blackholed UPSTREAM (TSPU drops
               it before it leaves the operator). Nothing local can reach it; only a
               foreign exit server helps.
    UNREACH  - no route at all (e.g. this machine has no working IPv6).

  Then it prints which server-less path (if any) your network allows.

  Run AS ADMINISTRATOR with the app fully CLOSED (a live TUN/proxy would route
  around the test and make every result meaningless):

      powershell -ExecutionPolicy Bypass -File tool\telegram-blockcheck.ps1
#>
[CmdletBinding()]
param([int]$TimeoutSec = 5)

$ErrorActionPreference = 'Stop'

# --- env sanity: a running app / live proxy routes around a direct test ---
$appRunning = [bool](Get-Process -Name vpn_app -ErrorAction SilentlyContinue)
if ($appRunning) {
  Write-Host 'WARNING: vpn_app is RUNNING. In TUN mode it captures even raw sockets,'  -ForegroundColor Yellow
  Write-Host '         so this would NOT be a clean direct test. Close it (tray -> exit) and re-run.' -ForegroundColor Yellow
  Write-Host ''
}
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ---------------------------------------------------------------------------
# Probe targets. The famous DC IPs DO listen on 443/80, so OPEN/RST/TIMEOUT is
# unambiguous on them. The extra per-/22 hosts may not listen, but RST-vs-TIMEOUT
# still reveals whether that whole prefix is blackholed.
$v4 = @(
  @{ ip = '149.154.175.50';  note = 'DC1 (149.154.160.0/20)' },
  @{ ip = '149.154.167.51';  note = 'DC2 (149.154.160.0/20)' },
  @{ ip = '149.154.175.100'; note = 'DC3 (149.154.160.0/20)' },
  @{ ip = '149.154.167.91';  note = 'DC4 (149.154.160.0/20)' },
  @{ ip = '91.108.56.130';   note = 'DC5 (91.108.56.0/22)'  },
  @{ ip = '91.108.4.10';     note = 'media (91.108.4.0/22)' },
  @{ ip = '91.108.8.10';     note = 'media (91.108.8.0/22)' },
  @{ ip = '91.108.12.10';    note = 'media (91.108.12.0/22)' },
  @{ ip = '91.108.16.10';    note = 'media (91.108.16.0/22)' },
  @{ ip = '91.108.20.10';    note = 'media (91.108.20.0/22)' },
  @{ ip = '95.161.64.10';    note = '95.161.64.0/20'        },
  @{ ip = '91.105.192.10';   note = '91.105.192.0/23'       },
  @{ ip = '185.76.151.10';   note = '185.76.151.0/24'       }
)
# Documented Telegram DC IPv6 host addresses (each ::a listens on 443).
$v6 = @(
  @{ ip = '2001:b28:f23d:f001::a'; note = 'DC1 v6 (2001:b28:f23d::/48)' },
  @{ ip = '2001:67c:4e8:f002::a';  note = 'DC2 v6 (2001:67c:4e8::/48)'  },
  @{ ip = '2001:b28:f23d:f003::a'; note = 'DC3 v6 (2001:b28:f23d::/48)' },
  @{ ip = '2001:67c:4e8:f004::a';  note = 'DC4 v6 (2001:67c:4e8::/48)'  },
  @{ ip = '2001:b28:f23f:f005::a'; note = 'DC5 v6 (2001:b28:f23f::/48)' }
)
# CIDRs (v4) for the winws --ipset anti-RST pass.
$v4cidrs = @(
  '91.108.4.0/22', '91.108.8.0/22', '91.108.12.0/22', '91.108.16.0/22',
  '91.108.20.0/22', '91.108.56.0/22', '95.161.64.0/20', '149.154.160.0/20',
  '91.105.192.0/23', '185.76.151.0/24'
)

# raw TCP connect, direct; classify reachability. Handles v4 and v6 literals.
function Test-Tcp([string]$ip, [int]$port, [int]$sec) {
  $addr = $null
  try { $addr = [System.Net.IPAddress]::Parse($ip) } catch { return 'BADIP' }
  $tcp = New-Object System.Net.Sockets.TcpClient($addr.AddressFamily)
  try {
    $iar = $tcp.BeginConnect($addr, $port, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($sec))) {
      try { $tcp.Close() } catch {}
      return 'TIMEOUT'
    }
    $tcp.EndConnect($iar)
    try { $tcp.Close() } catch {}
    return 'OPEN'
  } catch {
    try { $tcp.Close() } catch {}
    $ex = $_.Exception
    $se = $ex -as [System.Net.Sockets.SocketException]
    if ((-not $se) -and $ex.InnerException) {
      $se = $ex.InnerException -as [System.Net.Sockets.SocketException]
    }
    if ($se) {
      $code = $se.SocketErrorCode.ToString()
      if ($code -eq 'ConnectionRefused') { return 'RST' }
      if ($code -eq 'TimedOut') { return 'TIMEOUT' }
      if ($code -eq 'HostUnreachable' -or $code -eq 'NetworkUnreachable') { return 'UNREACH' }
      return "ERR:$code"
    }
    return 'FAIL'
  }
}

function Color-For([string]$s) {
  if ($s -eq 'OPEN') { return 'Green' }
  if ($s -eq 'RST')  { return 'Yellow' }
  if ($s -eq 'TIMEOUT') { return 'Red' }
  return 'DarkGray'
}

function Probe-Set($set, [int]$port) {
  $out = @()
  foreach ($t in $set) {
    $s = Test-Tcp $t.ip $port $TimeoutSec
    $out += @{ ip = $t.ip; note = $t.note; s = $s }
    $line = ('  {0,-24} {1,-30} ' -f $t.ip, $t.note)
    Write-Host $line -NoNewline
    Write-Host $s -ForegroundColor (Color-For $s)
  }
  return $out
}

Write-Host ''
Write-Host "Telegram block map (raw TCP, direct; timeout ${TimeoutSec}s)" -ForegroundColor Cyan
Write-Host ('admin={0}  app-running={1}' -f $admin, $appRunning) -ForegroundColor DarkGray
Write-Host ''

# --- control: prove the network itself is up (so TIMEOUTs mean Telegram, not "no net") ---
Write-Host 'CONTROL (must be OPEN - proves the net is up):' -ForegroundColor Cyan
$ctlV4 = Test-Tcp '1.1.1.1' 443 $TimeoutSec
Write-Host ('  {0,-24} {1,-30} ' -f '1.1.1.1', 'Cloudflare v4 :443') -NoNewline
Write-Host $ctlV4 -ForegroundColor (Color-For $ctlV4)
$ctlV6 = Test-Tcp '2606:4700:4700::1111' 443 $TimeoutSec
Write-Host ('  {0,-24} {1,-30} ' -f '2606:4700:4700::1111', 'Cloudflare v6 :443') -NoNewline
Write-Host $ctlV6 -ForegroundColor (Color-For $ctlV6)
$v6usable = ($ctlV6 -eq 'OPEN')
Write-Host ''

# --- Telegram v4 ---
Write-Host 'TELEGRAM v4 (:443):' -ForegroundColor Cyan
$r443 = Probe-Set $v4 443
Write-Host 'TELEGRAM v4 (:80):' -ForegroundColor Cyan
$r80 = Probe-Set $v4 80
Write-Host ''

# --- Telegram v6 (only meaningful if v6 control worked) ---
Write-Host 'TELEGRAM v6 (:443):' -ForegroundColor Cyan
if (-not $v6usable) {
  Write-Host '  (skipped - this machine has no working IPv6 route; control v6 was not OPEN)' -ForegroundColor DarkGray
  $r6 = @()
} else {
  $r6 = Probe-Set $v6 443
}
Write-Host ''

# --- Telegram HTTPS surface (web/api/core), via DoH to dodge a poisoned resolver ---
function Resolve-DoH([string]$h) {
  foreach ($res in @('1.1.1.1', '8.8.8.8', '9.9.9.9')) {
    try {
      $req = [System.Net.HttpWebRequest]::Create("https://$res/dns-query?name=$h&type=A")
      $req.Proxy = $null
      $req.Accept = 'application/dns-json'
      $req.Timeout = 5000
      $resp = $req.GetResponse()
      $txt = (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd()
      $resp.Close()
      $j = $txt | ConvertFrom-Json
      $a = $j.Answer | Where-Object { $_.type -eq 1 } | Select-Object -First 1
      if ($a) { return $a.data }
    } catch {}
  }
  return $null
}
function Test-Tls([string]$target, [string]$sni, [int]$sec) {
  if (-not $target) { return 'NO-DNS' }
  $tcp = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $tcp.BeginConnect($target, 443, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($sec))) { $tcp.Close(); return 'TCP-timeout' }
    $tcp.EndConnect($iar)
  } catch { $tcp.Close(); return 'TCP-fail' }
  try {
    $cb = [System.Net.Security.RemoteCertificateValidationCallback] { param($a, $b, $c, $d) $true }
    $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, $cb)
    $ssl.AuthenticateAsClient($sni)
    $ssl.Close(); $tcp.Close()
    return 'TLS-OK'
  } catch {
    $tcp.Close()
    $m = $_.Exception.Message
    if ($_.Exception.InnerException) { $m = $_.Exception.InnerException.Message }
    if ($m -match 'reset|forcibly|closed') { return 'TLS-reset' }
    return 'TLS-kill'
  }
}
Write-Host 'TELEGRAM HTTPS surface (real IP via DoH):' -ForegroundColor Cyan
foreach ($h in @('web.telegram.org', 'api.telegram.org', 'core.telegram.org')) {
  $ip = Resolve-DoH $h
  $tgt = $ip
  if (-not $tgt) { $tgt = $null }
  $s = Test-Tls $tgt $h $TimeoutSec
  $fg = 'Red'; if ($s -eq 'TLS-OK') { $fg = 'Green' } elseif ($s -match 'kill|reset') { $fg = 'Yellow' }
  Write-Host ('  {0,-24} {1,-30} ' -f $h, ("-> " + $tgt)) -NoNewline
  Write-Host $s -ForegroundColor $fg
}
Write-Host ''

# --- counts ---
$all4 = @($r443) + @($r80)
$open4 = (@($all4) | Where-Object { $_.s -eq 'OPEN' }).Count
$rst4  = (@($all4) | Where-Object { $_.s -eq 'RST' }).Count
$to4   = (@($all4) | Where-Object { $_.s -eq 'TIMEOUT' }).Count
$open6 = (@($r6) | Where-Object { $_.s -eq 'OPEN' }).Count
$rst6  = (@($r6) | Where-Object { $_.s -eq 'RST' }).Count

# --- optional winws anti-RST pass: only worth it if a v4 IP was REACHABLE (RST),
#     i.e. not a pure blackhole. Tries to flip RST -> OPEN with an IP-targeted desync. ---
$root = Split-Path $PSScriptRoot -Parent
$winws = Join-Path $root 'core\windows\winws.exe'
if ($rst4 -gt 0 -and (Test-Path $winws) -and $admin) {
  Write-Host 'winws anti-RST pass (v4 was REACHABLE via RST, so DPI-reset is plausible):' -ForegroundColor Cyan
  $ipset = Join-Path $env:TEMP 'tg_ipset.txt'
  ($v4cidrs -join "`n") | Out-File -FilePath $ipset -Encoding ascii
  $methods = [ordered]@{}
  $methods['split2 pos1 md5sig'] = @('--dpi-desync=fake,split2', '--dpi-desync-split-pos=1', '--dpi-desync-fooling=md5sig')
  $methods['syndata md5sig']     = @('--dpi-desync=syndata', '--dpi-desync-fooling=md5sig')
  $rstIps = @(@($r443) | Where-Object { $_.s -eq 'RST' } | ForEach-Object { $_.ip })
  if ($rstIps.Count -eq 0) { $rstIps = @(@($all4) | Where-Object { $_.s -eq 'RST' } | Select-Object -First 4 | ForEach-Object { $_.ip }) }
  foreach ($mname in $methods.Keys) {
    $a = @('--wf-tcp=443,80', '--filter-tcp=443,80') + $methods[$mname] + @("--ipset=$ipset")
    $wlog = Join-Path $env:TEMP 'tg_winws.txt'
    Remove-Item $wlog -ErrorAction SilentlyContinue
    $proc = Start-Process -FilePath $winws -ArgumentList $a -PassThru -WindowStyle Hidden `
      -RedirectStandardOutput $wlog -RedirectStandardError "$wlog.err"
    Start-Sleep -Seconds 3
    $cap = '-'
    if ($proc.HasExited) { $cap = "EXITED($($proc.ExitCode))" }
    else {
      $txt = ''
      foreach ($f in @($wlog, "$wlog.err")) { if (Test-Path $f) { $txt += (Get-Content $f -Raw -ErrorAction SilentlyContinue) } }
      if ($txt -match 'capture is started') { $cap = 'capture' }
    }
    Write-Host ("  [{0}]  winws={1}" -f $mname, $cap) -ForegroundColor DarkGray
    foreach ($ip in $rstIps) {
      $s = Test-Tcp $ip 443 $TimeoutSec
      Write-Host ('    {0,-24} :443  ' -f $ip) -NoNewline
      Write-Host $s -ForegroundColor (Color-For $s)
    }
    if ($null -ne $proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 1 }
  }
  Remove-Item $ipset -ErrorAction SilentlyContinue
  Write-Host ''
}

# ---------------------------------------------------------------------------
Write-Host '================ VERDICT ================' -ForegroundColor Cyan
if ($ctlV4 -ne 'OPEN') {
  Write-Host 'Control 1.1.1.1:443 was NOT open -> your network/egress is down or the app is still'  -ForegroundColor Red
  Write-Host 'routing traffic. Close the app and check your connection; results above are meaningless.' -ForegroundColor Red
}
elseif ($open4 -gt 0) {
  Write-Host "Some Telegram v4 IPs are OPEN ($open4). SERVER-LESS path EXISTS:" -ForegroundColor Green
  Write-Host '  -> route Telegram to a reachable IP locally (sing-box direct + override_address,'  -ForegroundColor Green
  Write-Host '     or a WinDivert dst-redirect). MTProto is IP-agnostic, so a live DC IP is enough.' -ForegroundColor Green
}
elseif ($v6usable -and $open6 -gt 0) {
  Write-Host "Telegram v4 is dead but v6 is OPEN ($open6). SERVER-LESS path EXISTS:" -ForegroundColor Green
  Write-Host '  -> force Telegram over IPv6 (operators routinely under-filter v6). Prefer v6 DC IPs'   -ForegroundColor Green
  Write-Host '     in routing; no server needed.' -ForegroundColor Green
}
elseif ($rst4 -gt 0 -or $rst6 -gt 0) {
  Write-Host 'Telegram IPs are REACHABLE but RST/refused (not blackholed). Possible DPI reset ->'  -ForegroundColor Yellow
  Write-Host '  -> the winws anti-RST pass above shows whether a desync flips RST to OPEN; if any did,' -ForegroundColor Yellow
  Write-Host '     a server-less winws+ipset rule for Telegram CIDRs is viable.' -ForegroundColor Yellow
}
else {
  Write-Host "Every Telegram IP TIMED OUT (v4 reachable-IPs and v6). This is a TRUE upstream"  -ForegroundColor Red
  Write-Host '  blackhole: TSPU drops packets to Telegram before they leave the operator. No local'  -ForegroundColor Red
  Write-Host '  trick (admin, WinDivert, routing) can reach a blackholed IP -- a FOREIGN EXIT SERVER' -ForegroundColor Red
  Write-Host '  is physically required for Telegram on this network.' -ForegroundColor Red
}
Write-Host '========================================='  -ForegroundColor Cyan
Write-Host ''
Write-Host 'Legend: OPEN=reachable+listening  RST=reachable+reset  TIMEOUT=blackholed  UNREACH=no route' -ForegroundColor Gray
