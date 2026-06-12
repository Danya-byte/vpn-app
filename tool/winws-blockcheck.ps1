<#
  winws-blockcheck.ps1  --  find a winws DPI-desync strategy that beats YOUR TSPU (RU DPI).

  Probes each blocked host with RAW sockets (TcpClient + SslStream), which go
  DIRECT and ignore any system proxy, so it measures the real network layer:

    TCP-timeout / TCP-fail  -> the IP/port itself is blocked (or the operator
                               collapsed to a whitelist). winws CANNOT help -
                               nothing to desync; you need a foreign exit server.
    TLS-kill / TLS-reset    -> TCP reaches, but the TLS ClientHello (SNI) is
                               killed by DPI. THIS is what winws targets.
    TLS-OK                  -> handshake completed = not blocked / DPI defeated.

  It sweeps several winws strategies and re-tests, so you see which (if any) flips
  a TLS-kill into TLS-OK.

  IMPORTANT: CLOSE / disconnect the app first. A live system-proxy or TUN routes
  traffic AROUND winws (which works on direct egress), so the test must run with
  the app off. Run AS ADMINISTRATOR (winws needs the WinDivert driver):

      powershell -ExecutionPolicy Bypass -File tool\winws-blockcheck.ps1
#>
[CmdletBinding()]
param([int]$TimeoutSec = 6, [int]$WarmupSec = 3)

$ErrorActionPreference = 'Stop'
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
  Write-Host 'ERROR: run AS ADMINISTRATOR - winws loads the WinDivert kernel driver.' -ForegroundColor Red
  exit 1
}

# --- environment sanity: a live proxy / running app routes around winws ---
$isKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$pe = (Get-ItemProperty $isKey -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable
$psrv = (Get-ItemProperty $isKey -Name ProxyServer -ErrorAction SilentlyContinue).ProxyServer
$appRunning = [bool](Get-Process -Name vpn_app -ErrorAction SilentlyContinue)
if ($pe -eq 1) {
  Write-Host "WARNING: system proxy is ON ($psrv). Raw sockets ignore it, but if it points at a dead 127.0.0.1 port that confirms the app left it set." -ForegroundColor Yellow
}
if ($appRunning) {
  Write-Host 'WARNING: vpn_app is RUNNING. In TUN mode it captures even raw sockets, so this would NOT be a clean direct test. Close the app fully (tray -> exit), then re-run.' -ForegroundColor Yellow
}

$root = Split-Path $PSScriptRoot -Parent
$cw = Join-Path $root 'core\windows'
$winws = Join-Path $cw 'winws.exe'
$quic = Join-Path $cw 'quic_initial.bin'
if (-not (Test-Path $winws)) {
  Write-Host "winws.exe not found: $winws  (run: tool\fetch-cores.ps1 -IncludeDesync)" -ForegroundColor Red
  exit 1
}
$haveQuic = Test-Path $quic

$hostList = @(
  'youtube.com', 'googlevideo.com', 'ytimg.com',
  'x.com', 'twitter.com', 'twimg.com', 't.co',
  'discord.com', 'discord.gg', 'discordapp.com',
  'linkedin.com', 'licdn.com', 'rutracker.org',
  't.me', 'telegram.org', 'web.telegram.org', 'core.telegram.org'
)
$hl = Join-Path $env:TEMP 'winws_bc_hosts.txt'
($hostList -join "`n") | Out-File -FilePath $hl -Encoding ascii

# probe targets: n=label, h=SNI host, t=connect target (default=h via system DNS;
# a literal IP connects DIRECTLY, bypassing a poisoned system resolver). The TG-*ip
# rows hit Telegram's PUBLISHED DC/CDN IPs directly to tell DNS-poisoning (IP
# reachable) from a true IP-block (IP itself dropped).
$sites = @(
  @{ n = 'YouTube';    h = 'www.youtube.com' },
  @{ n = 'X/Twitter';  h = 'x.com' },
  @{ n = 'Discord';    h = 'discord.com' },
  @{ n = 'LinkedIn';   h = 'www.linkedin.com' },
  @{ n = 'Rutracker';  h = 'rutracker.org' },
  @{ n = 'TG-sysdns';  h = 'web.telegram.org' },
  @{ n = 'TG-doh';     h = 'web.telegram.org'; doh = $true },
  @{ n = 'TGcore-doh'; h = 'core.telegram.org'; doh = $true }
)

$strats = [ordered]@{}
$strats['baseline (winws OFF)'] = $null
# datanoack (the fooling that beat LinkedIn) is the lead; vary the SPLIT POSITION
# (cut inside/around the SNI so DPI never sees the full name) + the desync method.
$strats['split2 pos1 +datanoack']      = @('--dpi-desync=fake,split2', '--dpi-desync-fooling=datanoack', '--dpi-desync-split-pos=1')
$strats['split2 sniext+1 +datanoack']  = @('--dpi-desync=fake,split2', '--dpi-desync-fooling=datanoack', '--dpi-desync-split-pos=sniext+1')
$strats['split2 host+1 +datanoack']    = @('--dpi-desync=fake,split2', '--dpi-desync-fooling=datanoack', '--dpi-desync-split-pos=host+1')
$strats['split2 midsld +datanoack']    = @('--dpi-desync=fake,split2', '--dpi-desync-fooling=datanoack', '--dpi-desync-split-pos=midsld')
$strats['multisplit SNI +datanoack']   = @('--dpi-desync=fake,multisplit', '--dpi-desync-fooling=datanoack', '--dpi-desync-split-pos=1,midsld,sniext+1,host+1')
$strats['fakedsplit sniext +datanoack']= @('--dpi-desync=fake,fakedsplit', '--dpi-desync-fooling=datanoack', '--dpi-desync-split-pos=sniext+1')
$strats['disorder2 +datanoack']        = @('--dpi-desync=fake,disorder2', '--dpi-desync-fooling=datanoack', '--dpi-desync-split-pos=1')
$strats['multidisorder SNI +datanoack']= @('--dpi-desync=fake,multidisorder', '--dpi-desync-fooling=datanoack', '--dpi-desync-split-pos=1,midsld,sniext+1')
# padencap escalation: pad the FAKE ClientHello to the SAME record length as the
# real one so a length-tracking stateful TSPU consumes the decoy, classifies the
# flow on the benign sni=, and is offset/sated when the real split CH arrives.
# Binary-verified the bundled winws supports fake-tls-mod=padencap|sni=<h>|dupsid.
# Rows isolate the levers: padencap+RUsni / split2 / RUsni-alone / padencap+dupsid.
$strats['multidisord +datanoack+padencap+RUsni']  = @('--dpi-desync=fake,multidisorder', '--dpi-desync-fooling=datanoack', '--dpi-desync-split-pos=1,midsld,sniext+1', '--dpi-desync-fake-tls-mod=padencap,sni=gosuslugi.ru')
$strats['split2 sniext +datanoack+padencap']      = @('--dpi-desync=fake,split2', '--dpi-desync-fooling=datanoack', '--dpi-desync-split-pos=sniext+1', '--dpi-desync-fake-tls-mod=padencap,sni=gosuslugi.ru')
$strats['multidisord +datanoack+RUsni (no pad)']  = @('--dpi-desync=fake,multidisorder', '--dpi-desync-fooling=datanoack', '--dpi-desync-split-pos=1,midsld,sniext+1', '--dpi-desync-fake-tls-mod=sni=gosuslugi.ru')
$strats['multidisord +datanoack+padencap+dupsid'] = @('--dpi-desync=fake,multidisorder', '--dpi-desync-fooling=datanoack', '--dpi-desync-split-pos=1,midsld,sniext+1', '--dpi-desync-fake-tls-mod=padencap,dupsid')
$strats['split2 sniext +datanoack+ttl']= @('--dpi-desync=fake,split2', '--dpi-desync-fooling=datanoack', '--dpi-desync-split-pos=sniext+1', '--dpi-desync-autottl=2')
$strats['syndata +datanoack']          = @('--dpi-desync=syndata', '--dpi-desync-fooling=datanoack')
$strats['split2 multi-pos +datanoack'] = @('--dpi-desync=fake,split2', '--dpi-desync-fooling=datanoack', '--dpi-desync-split-pos=1,2,5,sniext+1')

# Resolve a host via DoH (HTTPS to a public resolver) - bypasses a poisoned system
# DNS, so we connect to the host's REAL IP. Returns the first A record, or null.
function Resolve-DoH([string]$h) {
  foreach ($r in @('1.1.1.1', '8.8.8.8', '9.9.9.9')) {
    try {
      $req = [System.Net.HttpWebRequest]::Create("https://$r/dns-query?name=$h&type=A")
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

# raw TCP connect to [target], then TLS handshake sending SNI=[sni] - DIRECT,
# ignores any proxy AND any system DNS (target may be a literal IP).
function Test-Host([string]$target, [string]$sni, [int]$sec) {
  $tcp = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $tcp.BeginConnect($target, 443, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($sec))) {
      $tcp.Close(); return @{ ok = $false; s = 'TCP-timeout' }
    }
    $tcp.EndConnect($iar)
  } catch {
    $tcp.Close(); return @{ ok = $false; s = 'TCP-fail' }
  }
  $tcp.ReceiveTimeout = $sec * 1000
  $tcp.SendTimeout = $sec * 1000
  try {
    $cb = [System.Net.Security.RemoteCertificateValidationCallback] { param($a, $b, $c, $d) $true }
    $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, $cb)
    $ssl.AuthenticateAsClient($sni)
    $ssl.Close(); $tcp.Close()
    return @{ ok = $true; s = 'TLS-OK' }
  } catch {
    $tcp.Close()
    $m = $_.Exception.Message
    if ($_.Exception.InnerException) { $m = $_.Exception.InnerException.Message }
    if ($m -match 'reset|forcibly|closed') { return @{ ok = $false; s = 'TLS-reset' } }
    return @{ ok = $false; s = 'TLS-kill' }
  }
}

function Start-Winws([string[]]$method) {
  $a = @('--wf-tcp=80,443')
  if ($haveQuic) { $a += '--wf-udp=443' }
  $a += @('--filter-tcp=443') + $method + @("--hostlist=$hl", '--new', '--filter-tcp=80') + $method + @("--hostlist=$hl")
  if ($haveQuic) {
    $a += @('--new', '--filter-udp=443', '--dpi-desync=fake', '--dpi-desync-repeats=6', "--dpi-desync-fake-quic=$quic", "--hostlist=$hl")
  }
  $script:wlog = Join-Path $env:TEMP 'winws_bc_out.txt'
  Remove-Item $script:wlog -ErrorAction SilentlyContinue
  return Start-Process -FilePath $winws -ArgumentList $a -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $script:wlog -RedirectStandardError "$script:wlog.err"
}

# Did winws actually start capturing? (proves the engine is live vs. silently dead)
function Winws-Status {
  $txt = ''
  foreach ($f in @($script:wlog, "$script:wlog.err")) {
    if (Test-Path $f) { $txt += (Get-Content $f -Raw -ErrorAction SilentlyContinue) }
  }
  if ($txt -match 'capture is started') {
    $hn = '?'
    if ($txt -match 'Loaded (\d+) hosts') { $hn = $matches[1] }
    return "capture+$hn"
  }
  $errline = ($txt -split "`r?`n" | Where-Object { $_ -match 'error|fail|cannot|denied|in use' } | Select-Object -First 1)
  if ($errline) { return "ERR: $($errline.Trim())" }
  if ($txt.Trim().Length -gt 0) { return 'started?' }
  return 'NO OUTPUT'
}

Write-Host ''
Write-Host ("winws blockcheck (raw TCP+TLS, direct; timeout ${TimeoutSec}s, quic=$haveQuic)") -ForegroundColor Cyan
$hdr = ('{0,-26}' -f 'STRATEGY')
foreach ($s in $sites) { $hdr += ('{0,-13}' -f $s.n) }
Write-Host $hdr -ForegroundColor Gray

foreach ($name in $strats.Keys) {
  $method = $strats[$name]
  $proc = $null
  $wst = '-'
  if ($null -ne $method) {
    $proc = Start-Winws $method
    Start-Sleep -Seconds $WarmupSec
    if ($proc.HasExited) { $wst = "EXITED($($proc.ExitCode))" } else { $wst = Winws-Status }
  }
  Write-Host ('{0,-26}' -f $name) -NoNewline
  foreach ($s in $sites) {
    $tgt = $s.h
    if ($s.ContainsKey('t')) { $tgt = $s.t }
    elseif ($s.ContainsKey('doh')) {
      $tgt = Resolve-DoH $s.h
      if (-not $tgt) { $tgt = '0.0.0.0' } # DoH itself blocked -> forces TCP-fail
    }
    $r = Test-Host $tgt $s.h $TimeoutSec
    if ($r.ok) { $fg = 'Green' } else { $fg = 'Red' }
    Write-Host ('{0,-13}' -f $r.s) -ForegroundColor $fg -NoNewline
  }
  $wfg = 'DarkGray'
  if ($wst -match 'capture') { $wfg = 'Green' } elseif ($wst -match 'ERR|EXITED|NO OUTPUT') { $wfg = 'Red' }
  Write-Host ("  [winws: $wst]") -ForegroundColor $wfg
  if ($null -ne $proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 1 }
}

Remove-Item $hl -ErrorAction SilentlyContinue
Write-Host ''
Write-Host 'TCP-timeout/TCP-fail  = IP/port blocked (or operator whitelist) -> winws CANNOT help, need a server.' -ForegroundColor Gray
Write-Host 'TLS-kill/TLS-reset    = TCP reaches but DPI kills the TLS handshake -> winws SHOULD fix this.' -ForegroundColor Gray
Write-Host 'TLS-OK (green)        = handshake completed = not blocked / DPI defeated.' -ForegroundColor Gray
Write-Host 'If baseline shows TCP-timeout everywhere, the app is likely still routing traffic (TUN/proxy) -' -ForegroundColor Gray
Write-Host 'close it fully and re-run; raw sockets must reach the net directly for this test to mean anything.' -ForegroundColor Gray
