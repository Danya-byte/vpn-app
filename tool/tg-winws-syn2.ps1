# tg-winws-syn2.ps1 - round 2: the winws SYN strategies I skipped in round 1.
#
# Round 1 tried the obvious fake/syndata foolings -> all TIMEOUT. But the middlebox
# drops "SYN to Telegram" -- the question is WHAT it keys on:
#   - if it needs the TCP header (SYN flag / dst port 443), then IP-FRAGMENTING the SYN
#     so the TCP header lands in the 2nd fragment hides the classifier's key -> it may
#     pass the 1st fragment (dst-IP only) and not reassemble. Telegram reassembles. WIN.
#   - datanoack is the exact fooling that beat THIS operator's DPI on LinkedIn/YouTube
#     (per our own desync_config), never tried at the SYN.
#   - seqovl / manual TTL / hop counts I also skipped.
#
# If ANY cell turns OPEN!!, that strategy cracked the SYN drop -> server-less, we build
# it in. If all TIMEOUT again, the drop is a pure proto+dst-IP ACL (in EVERY fragment's
# IP header) and only a custom WinDivert packet-mangler could still help -- next step.
#
# RUN AS ADMINISTRATOR, app FULLY CLOSED.

$ErrorActionPreference = 'Stop'
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Host 'ERROR: run AS ADMINISTRATOR (WinDivert driver).' -ForegroundColor Red; exit 1 }
if (Get-Process -Name vpn_app -ErrorAction SilentlyContinue) {
  Write-Host 'WARNING: vpn_app running -- close it fully (TUN routes around winws).' -ForegroundColor Yellow
}

$root = Split-Path $PSScriptRoot -Parent
$winws = Join-Path $root 'core\windows\winws.exe'
if (-not (Test-Path $winws)) { Write-Host "winws.exe not found ($winws)." -ForegroundColor Red; exit 1 }

$dcs = @('149.154.167.51', '149.154.175.50', '91.108.56.130')
$ipset = Join-Path $env:TEMP 'tg_ipset2.txt'
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
function Start-Winws([string[]]$m) {
  $a = @('--wf-tcp=443', '--filter-tcp=443', "--ipset=$ipset") + $m
  $script:wlog = Join-Path $env:TEMP 'tg_winws2_out.txt'
  Remove-Item $script:wlog, "$script:wlog.err" -ErrorAction SilentlyContinue
  return Start-Process -FilePath $winws -ArgumentList $a -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $script:wlog -RedirectStandardError "$script:wlog.err"
}
function Winws-Up {
  $t = ''; foreach ($f in @($script:wlog, "$script:wlog.err")) { if (Test-Path $f) { $t += (Get-Content $f -Raw -EA SilentlyContinue) } }
  if ($t -match 'capture is started') { return 'capture' }
  $e = ($t -split "`r?`n" | Where-Object { $_ -match 'error|fail|cannot|denied|in use|unknown|invalid' } | Select-Object -First 1)
  if ($e) { return "ERR:$($e.Trim().Substring(0,[Math]::Min(40,$e.Trim().Length)))" }
  return 'started?'
}

$strats = [ordered]@{}
$strats['baseline (OFF)']            = $null
$strats['ipfrag2']                   = @('--dpi-desync=ipfrag2', '--dpi-desync-any-protocol=1')
$strats['ipfrag2 pos-tcp=8']         = @('--dpi-desync=ipfrag2', '--dpi-desync-any-protocol=1', '--dpi-desync-ipfrag-pos-tcp=8')
$strats['ipfrag2 pos-tcp=16']        = @('--dpi-desync=ipfrag2', '--dpi-desync-any-protocol=1', '--dpi-desync-ipfrag-pos-tcp=16')
$strats['ipfrag2+fake md5sig']       = @('--dpi-desync=ipfrag2,fake', '--dpi-desync-any-protocol=1', '--dpi-desync-fooling=md5sig')
$strats['fake datanoack autottl']    = @('--dpi-desync=fake', '--dpi-desync-any-protocol=1', '--dpi-desync-fooling=datanoack', '--dpi-desync-autottl=2')
$strats['syndata datanoack']         = @('--dpi-desync=syndata', '--dpi-desync-fooling=datanoack')
$strats['disorder2 any']             = @('--dpi-desync=disorder2', '--dpi-desync-any-protocol=1')
$strats['split2 any seqovl1']        = @('--dpi-desync=split2', '--dpi-desync-any-protocol=1', '--dpi-desync-split-pos=1', '--dpi-desync-split-seqovl=1')
$strats['fake md5sig ttl=1']         = @('--dpi-desync=fake', '--dpi-desync-any-protocol=1', '--dpi-desync-fooling=md5sig', '--dpi-desync-ttl=1')
$strats['fake md5sig ttl=3']         = @('--dpi-desync=fake', '--dpi-desync-any-protocol=1', '--dpi-desync-fooling=md5sig', '--dpi-desync-ttl=3')
$strats['fake md5sig ttl=5']         = @('--dpi-desync=fake', '--dpi-desync-any-protocol=1', '--dpi-desync-fooling=md5sig', '--dpi-desync-ttl=5')

Write-Host ''
Write-Host 'winws SYN-desync vs Telegram, ROUND 2 (any OPEN!! = CRACKED)' -ForegroundColor Cyan
$hdr = ('{0,-26}' -f 'STRATEGY'); foreach ($d in $dcs) { $hdr += ('{0,-11}' -f $d.Split('.')[-1]) }
Write-Host $hdr -ForegroundColor Gray
foreach ($name in $strats.Keys) {
  $m = $strats[$name]; $proc = $null; $up = '-'
  if ($null -ne $m) { $proc = Start-Winws $m; Start-Sleep -Seconds 3; $up = if ($proc.HasExited) { "EXIT($($proc.ExitCode))" } else { Winws-Up } }
  Write-Host ('{0,-26}' -f $name) -NoNewline
  foreach ($d in $dcs) {
    $r = Test-Tcp $d 443 5
    Write-Host ('{0,-11}' -f $r) -ForegroundColor $(if ($r -eq 'OPEN!!') { 'Green' } else { 'Red' }) -NoNewline
  }
  Write-Host ("  [$up]") -ForegroundColor $(if ($up -match 'capture') { 'Green' } elseif ($up -match 'ERR|EXIT') { 'Red' } else { 'DarkGray' })
  if ($null -ne $proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue; Start-Sleep 1 }
}
Remove-Item $ipset -EA SilentlyContinue
Write-Host ''
Write-Host 'Watch the [..] column: [capture]=strategy ran; [ERR/EXIT]=bad flag (ignore that row).' -ForegroundColor Gray
Write-Host 'Any OPEN!! = we cracked it server-less. If ipfrag rows are [capture] yet TIMEOUT, the' -ForegroundColor Gray
Write-Host 'box keys on the IP header alone -> next I build OUR OWN WinDivert mangler (SYN-flag /' -ForegroundColor Gray
Write-Host 'IP-option ambiguity zapret cannot do). Send the table.' -ForegroundColor Gray
