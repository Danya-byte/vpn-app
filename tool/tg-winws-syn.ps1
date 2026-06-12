# tg-winws-syn.ps1 - can winws (WinDivert) desync Telegram's TCP-SYN drop?
#
# BREAKTHROUGH from tg-deep-probe: Telegram is NOT null-routed -- ICMP reaches the DC
# (tracert hit 149.154.167.51 at hop 11), but the TCP SYN is dropped by a middlebox on
# the Telegram-specific routed path. Packets physically reach Telegram, so if we can
# slip the SYN past that box, Telegram answers -- server-less, no intermediate.
#
# winws's TLS-ClientHello tricks don't apply (no handshake to reach). But its SYN-stage
# desync does: a FAKE SYN (md5sig/badseq, low TTL) that the middlebox processes but the
# server rejects, sent just before the real SYN -- the classic SYN-drop evasion. This
# matches winws by DESTINATION IP (ipset = Telegram CIDRs), not SNI, so it fires on the
# SYN itself. If ANY strategy flips a Telegram DC from TIMEOUT to OPEN, we cracked it.
#
# RUN AS ADMINISTRATOR, with the app FULLY CLOSED (TUN/proxy would route around winws).

$ErrorActionPreference = 'Stop'
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Host 'ERROR: run AS ADMINISTRATOR (winws needs the WinDivert driver).' -ForegroundColor Red; exit 1 }
if (Get-Process -Name vpn_app -ErrorAction SilentlyContinue) {
  Write-Host 'WARNING: vpn_app is running -- close it fully (tray -> exit); TUN routes around winws.' -ForegroundColor Yellow
}

$root = Split-Path $PSScriptRoot -Parent
$winws = Join-Path $root 'core\windows\winws.exe'
if (-not (Test-Path $winws)) { Write-Host "winws.exe not found ($winws). Run tool\fetch-cores.ps1 -IncludeDesync." -ForegroundColor Red; exit 1 }

# Telegram DC IPs to test the SYN against (a TCP OPEN here = SYN got through).
$dcs = @('149.154.167.51', '149.154.175.50', '91.108.56.130')
# ipset = every published Telegram CIDR (winws matches the SYN by dst IP, not SNI).
$ipset = Join-Path $env:TEMP 'tg_ipset.txt'
@'
149.154.160.0/20
91.108.4.0/22
91.108.8.0/22
91.108.12.0/22
91.108.16.0/22
91.108.20.0/22
91.108.56.0/22
95.161.64.0/20
91.105.192.0/23
185.76.151.0/24
'@ | Out-File -FilePath $ipset -Encoding ascii

function Test-Tcp($ip, $port, $sec) {
  $c = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $c.BeginConnect($ip, $port, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($sec))) { $c.Close(); return 'TIMEOUT' }
    $c.EndConnect($iar); $c.Close(); return 'OPEN!!'
  } catch { try { $c.Close() } catch {}; return 'RST/err' }
}

function Start-Winws([string[]]$method) {
  $a = @('--wf-tcp=443', '--filter-tcp=443', "--ipset=$ipset") + $method
  $script:wlog = Join-Path $env:TEMP 'tg_winws_out.txt'
  Remove-Item $script:wlog -ErrorAction SilentlyContinue
  Remove-Item "$script:wlog.err" -ErrorAction SilentlyContinue
  return Start-Process -FilePath $winws -ArgumentList $a -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $script:wlog -RedirectStandardError "$script:wlog.err"
}
function Winws-Up {
  $t = ''
  foreach ($f in @($script:wlog, "$script:wlog.err")) { if (Test-Path $f) { $t += (Get-Content $f -Raw -EA SilentlyContinue) } }
  if ($t -match 'capture is started') { return 'capture' }
  $e = ($t -split "`r?`n" | Where-Object { $_ -match 'error|fail|cannot|denied|in use|unknown' } | Select-Object -First 1)
  if ($e) { return "ERR:$($e.Trim())" }
  return 'started?'
}

# SYN-stage desync strategies (each works ON the SYN, matched by dst IP):
$strats = [ordered]@{}
$strats['baseline (winws OFF)']      = $null
$strats['syndata']                   = @('--dpi-desync=syndata')
$strats['syndata +md5sig']           = @('--dpi-desync=syndata', '--dpi-desync-fooling=md5sig')
$strats['fake any +md5sig +autottl'] = @('--dpi-desync=fake', '--dpi-desync-any-protocol=1', '--dpi-desync-fooling=md5sig', '--dpi-desync-autottl=2')
$strats['fake any +badseq +autottl'] = @('--dpi-desync=fake', '--dpi-desync-any-protocol=1', '--dpi-desync-fooling=badseq', '--dpi-desync-autottl=2')
$strats['fake any +badsum']          = @('--dpi-desync=fake', '--dpi-desync-any-protocol=1', '--dpi-desync-fooling=badsum')
$strats['fakedsplit any +md5sig']    = @('--dpi-desync=fakedsplit', '--dpi-desync-any-protocol=1', '--dpi-desync-fooling=md5sig')
$strats['fake any md5+badseq rep4']  = @('--dpi-desync=fake', '--dpi-desync-any-protocol=1', '--dpi-desync-fooling=md5sig,badseq', '--dpi-desync-repeats=4', '--dpi-desync-autottl=3')

Write-Host ''
Write-Host 'winws SYN-desync vs Telegram (any OPEN!! = CRACKED, server-less)' -ForegroundColor Cyan
$hdr = ('{0,-28}' -f 'STRATEGY'); foreach ($d in $dcs) { $hdr += ('{0,-12}' -f $d.Split('.')[-1]) }
Write-Host $hdr -ForegroundColor Gray

foreach ($name in $strats.Keys) {
  $method = $strats[$name]; $proc = $null; $up = '-'
  if ($null -ne $method) {
    $proc = Start-Winws $method
    Start-Sleep -Seconds 3
    if ($proc.HasExited) { $up = "EXIT($($proc.ExitCode))" } else { $up = Winws-Up }
  }
  Write-Host ('{0,-28}' -f $name) -NoNewline
  foreach ($d in $dcs) {
    $r = Test-Tcp $d 443 5
    $fg = if ($r -eq 'OPEN!!') { 'Green' } else { 'Red' }
    Write-Host ('{0,-12}' -f $r) -ForegroundColor $fg -NoNewline
  }
  $wfg = if ($up -match 'capture') { 'Green' } elseif ($up -match 'ERR|EXIT') { 'Red' } else { 'DarkGray' }
  Write-Host ("  [$up]") -ForegroundColor $wfg
  if ($null -ne $proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue; Start-Sleep 1 }
}
Remove-Item $ipset -EA SilentlyContinue
Write-Host ''
Write-Host 'baseline TIMEOUT everywhere is expected. ANY green OPEN!! on a strategy = winws' -ForegroundColor Gray
Write-Host 'desynced the SYN drop -> server-less Telegram is REAL on your net; we build that' -ForegroundColor Gray
Write-Host 'strategy into the app (ipset=Telegram + SYN-desync). If all stay TIMEOUT, the SYN' -ForegroundColor Gray
Write-Host 'drop is stateless (pure dst-IP ACL) -> not desyncable, an intermediate is required.' -ForegroundColor Gray
