# Kill-switch leak-test harness (run on REAL Windows hardware).
#
# Automates the objective part of the kill-switch leak test: with the tunnel up it
# kills the core to simulate a crash, then probes egress on the PHYSICAL path
# across EVERY vector a leak can take - ICMP, raw TCP, DNS (UDP+TCP), and IPv6 -
# and prints PASS/FAIL. ICMP alone is NOT enough: a fence that drops ping but
# leaks TCP/DNS/v6 would falsely PASS.
#
# Usage (from the repo root, app already BUILT):
#   1. Launch the app, enable TUN mode + the kill-switch, "Restart as admin",
#      connect to a node, confirm the exit IP differs from your real IP.
#   2. In an ADMIN PowerShell:  ./tool/leak-test.ps1
#   3. PASS = ALL egress STOPS when the core dies (fail-closed).
#
# Repeat once per transport you ship: Reality, then XHTTP/Reality-over-XHTTP
# (the script also kills xray.exe), per the H1 fix.

param(
  [int]$Samples = 4,                          # repeat the probe set N times after the kill
  [string]$V4 = '1.1.1.1',                    # IPv4 target (ICMP + TCP)
  [string]$V6 = '2606:4700:4700::1111',       # IPv6 target (TCP)
  [string]$DnsServer = '8.8.8.8'              # public resolver for the DNS probe
)

$ErrorActionPreference = 'Stop'

function Test-Tcp([string]$ip, [int]$port, [int]$timeoutMs = 1500) {
  # Raw TCP connect with a hard timeout (faster + more reliable than
  # Test-NetConnection). True = the SYN got out and a SYN-ACK came back.
  try {
    $c = New-Object System.Net.Sockets.TcpClient
    $iar = $c.BeginConnect($ip, $port, $null, $null)
    $hit = $iar.AsyncWaitHandle.WaitOne($timeoutMs)
    $up = $hit -and $c.Connected
    $c.Close()
    return $up
  } catch { return $false }
}

function Get-Leaks {
  # Every egress vector that GOT OUT on the physical path. Empty = fail-closed.
  $leaks = @()
  if (Test-Connection -ComputerName $V4 -Count 1 -Quiet -ErrorAction SilentlyContinue) { $leaks += 'ICMPv4' }
  if (Test-Tcp $V4 443) { $leaks += "TCPv4 ${V4}:443" }
  try {
    $null = Resolve-DnsName -Name 'example.com' -Server $DnsServer -QuickTimeout -ErrorAction Stop
    $leaks += "DNS ${DnsServer}:53"
  } catch {}
  if (Test-Tcp $V6 443) { $leaks += "TCPv6 [$V6]:443" }
  # ICMPv6 Echo (ping -6): a blanket ICMPv6 permit would leak v6 ping, which a
  # TCP-only v6 probe misses. The fence must permit ONLY Neighbor Discovery
  # (types 133-136), so an Echo reply here is a real leak.
  if (Test-Connection -ComputerName $V6 -Count 1 -Quiet -ErrorAction SilentlyContinue) { $leaks += 'ICMPv6' }
  return $leaks
}

Write-Host '== Kill-switch leak-test (ICMP / TCP / DNS / IPv6) ==' -ForegroundColor Cyan

# A v6 "no leak" result is vacuous on a host with no routable IPv6 (the probes
# can't reach out regardless of the fence). Say so, so a PASS isn't false comfort.
$hasV6 = @(Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue |
  Where-Object { $_.IPAddress -notlike 'fe80*' -and $_.IPAddress -ne '::1' }).Count -gt 0
if (-not $hasV6) {
  Write-Host 'NOTE: no routable IPv6 on this host - the IPv6 probes are vacuous; a v6 PASS does NOT prove v6 containment. Re-run on a dual-stack network to verify the v6 fence.' -ForegroundColor Yellow
}

$core = Get-Process -Name 'sing-box' -ErrorAction SilentlyContinue
if (-not $core) {
  Write-Host 'sing-box.exe is not running. Connect via the app (TUN + kill-switch ON) first.' -ForegroundColor Yellow
  exit 2
}

# Baseline: with the tunnel UP, at least one vector should reach the internet
# (through the tunnel) - otherwise you are not actually connected.
$before = Get-Leaks
Write-Host "Baseline (tunnel up): egress via [$($before -join ', ')]"
if ($before.Count -eq 0) {
  Write-Host 'No egress even before the kill - not a valid test (are you actually connected?).' -ForegroundColor Yellow
  exit 2
}

Write-Host 'Killing sing-box.exe (+ any xray bridge) to simulate a core crash...' -ForegroundColor Yellow
$core | Stop-Process -Force
Get-Process -Name 'xray' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 1000  # let the tunnel die; the fence must remain

# Probe several times - an intermittent leak still fails.
$leaked = @()
for ($i = 0; $i -lt $Samples; $i++) {
  $leaked += Get-Leaks
  Start-Sleep -Milliseconds 500
}
$leaked = @($leaked | Select-Object -Unique)

if ($leaked.Count -ne 0) {
  Write-Host "FAIL: LEAK via [$($leaked -join ', ')] - the fence is NOT blocking the physical NIC." -ForegroundColor Red
  Write-Host 'Do NOT enable killSwitchTun by default. Check WFP sublayer arbitration (CLEAR_ACTION_RIGHT) + the per-protocol permits.'
  exit 1
}
Write-Host 'PASS: fail-CLOSED - NO egress on the physical NIC (ICMPv4/v6 / TCP / DNS) after the core died.' -ForegroundColor Green

# Anti-lockout half (automated): closing the app must DROP the dynamic WFP fence
# so the machine gets its internet back. Kill vpn_app.exe and confirm egress
# RETURNS - a fence that survives the process is a real lockout.
$app = Get-Process -Name 'vpn_app' -ErrorAction SilentlyContinue
if (-not $app) {
  Write-Host '(vpn_app.exe not found - skipping the fence-drops-on-close check.)'
  exit 0
}
Write-Host 'Closing vpn_app.exe to verify the fence drops on exit...' -ForegroundColor Yellow
$app | Stop-Process -Force
Start-Sleep -Milliseconds 1500
$after = Get-Leaks
if ($after.Count -gt 0) {
  Write-Host "PASS: fence DROPPED on close - egress restored via [$($after -join ', ')] (no lockout)." -ForegroundColor Green
  exit 0
} else {
  Write-Host 'FAIL: no egress even after closing the app - the fence did NOT drop (LOCKOUT risk).' -ForegroundColor Red
  Write-Host 'Verify the WFP session is DYNAMIC (auto-purge on exit) + OnDestroy KillSwitchDisengage.'
  exit 1
}
