# Kill-switch leak-test harness (run on REAL Windows hardware).
#
# Automates the objective part of PREPROD-CHECKLIST §2: it probes egress on the
# PHYSICAL NIC, kills the core to simulate a crash, and prints a PASS/FAIL verdict
# — instead of you eyeballing a ping window. You still drive the app's connect
# (the app needs UAC for TUN); the script handles the probe + kill + verdict.
#
# Usage (from the repo root, app already BUILT):
#   1. Launch the app, enable TUN mode + the kill-switch, "Restart as admin",
#      connect to a node, and confirm the exit IP differs from your real IP.
#   2. In an ADMIN PowerShell:  ./tool/leak-test.ps1
#   3. Follow the prompt. PASS = egress STOPS when the core dies (fail-closed).
#
# Repeat once per transport you ship: Reality, then XHTTP/Reality-over-XHTTP
# (also kill xray.exe), per the H1 fix.

param(
  [string]$Probe = '8.8.8.8',  # a host that only answers if you actually have egress
  [int]$Samples = 5            # ICMP probes after the kill before deciding
)

$ErrorActionPreference = 'Stop'

function Test-Egress([string]$ip, [int]$n) {
  # Returns the number of ICMP replies (0 = no egress = fail-closed).
  $ok = 0
  for ($i = 0; $i -lt $n; $i++) {
    if (Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue) { $ok++ }
    Start-Sleep -Milliseconds 600
  }
  return $ok
}

Write-Host '== Kill-switch leak-test ==' -ForegroundColor Cyan

$core = Get-Process -Name 'sing-box' -ErrorAction SilentlyContinue
if (-not $core) {
  Write-Host 'sing-box.exe is not running. Connect via the app (TUN + kill-switch ON) first.' -ForegroundColor Yellow
  exit 2
}

# Baseline: with the tunnel UP, egress should work (through the tunnel).
$before = Test-Egress $Probe 3
Write-Host "Baseline egress (tunnel up): $before/3 replies"
if ($before -eq 0) {
  Write-Host 'No egress even before the kill — not a valid test (are you actually connected?).' -ForegroundColor Yellow
  exit 2
}

Write-Host 'Killing sing-box.exe to simulate a core crash...' -ForegroundColor Yellow
$core | Stop-Process -Force
# Also kill any xray bridge, so the XHTTP/Reality-over-XHTTP run is a true test.
Get-Process -Name 'xray' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 800  # let the fence remain / routes settle

$after = Test-Egress $Probe $Samples
Write-Host "Egress AFTER core death: $after/$Samples replies"

if ($after -eq 0) {
  Write-Host 'PASS: fail-CLOSED — no egress on the physical NIC after the core died.' -ForegroundColor Green
  Write-Host 'Now: confirm the app auto-reconnects, and that closing the app restores normal internet within ~1s.'
  exit 0
} else {
  Write-Host "FAIL: LEAK — $after/$Samples probes still got out. The fence is NOT blocking the physical NIC." -ForegroundColor Red
  Write-Host 'Do NOT set killSwitchTun default-ON. Investigate the WFP sublayer arbitration (CLEAR_ACTION_RIGHT / competing VPN sublayer).'
  exit 1
}
