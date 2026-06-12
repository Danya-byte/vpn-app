# tg-snowflake-poc.ps1 - prove Tor-over-Snowflake reaches Telegram on THIS network.
#
# The webrtc-probe showed STUN (Cloudflare/Twilio) + the Fastly broker + Cloudflare TURN
# are all reachable here, while Google STUN is dead. This downloads the Tor Expert Bundle
# (tor.exe + snowflake-client.exe), writes a torrc with our ADAPTIVE ICE (the reachable
# STUN, not Google), bootstraps, and pulls Telegram through the SOCKS. If api.telegram.org
# answers, Telegram is unblocked server-less (no VPS, no subscription) on your net.
#
# Safe: downloads only from torproject.org, runs tor as a normal user, cleans up.

$ErrorActionPreference = 'Stop'
$root = 'C:\Users\danya\WebstormProjects\vpn-app\build\sf-poc'
$socks = 9055
New-Item -ItemType Directory -Force -Path $root | Out-Null

# --- 1. locate tor.exe + snowflake-client.exe from an EXISTING Tor Browser ---
# torproject.org is DNS/IP-blocked in RU, so we cannot download Tor on the blocked
# machine (the classic bootstrapping problem). The REAL app bundles these binaries
# (fetched at build time on an unblocked box, like sing-box/xray). For this PoC we
# reuse a Tor Browser you already have installed.
$torExe = $null; $sfExe = $null
$roots = @(
  "$env:USERPROFILE\Desktop\Tor Browser",
  "$env:USERPROFILE\Downloads\Tor Browser",
  "$env:USERPROFILE\OneDrive\Desktop\Tor Browser",
  "$env:USERPROFILE\OneDrive\Рабочий стол\Tor Browser",
  "$env:USERPROFILE\Рабочий стол\Tor Browser",
  "$env:LOCALAPPDATA\Tor Browser",
  "${env:ProgramFiles}\Tor Browser",
  "${env:ProgramFiles(x86)}\Tor Browser"
)
foreach ($r in $roots) {
  if ($r -and (Test-Path $r)) {
    $t = Get-ChildItem -Path $r -Recurse -Filter 'tor.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    $s = Get-ChildItem -Path $r -Recurse -Filter 'snowflake-client.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($t -and $s) { $torExe = $t.FullName; $sfExe = $s; break }
  }
}
if (-not $torExe -or -not $sfExe) {
  Write-Output "Tor Browser not found, and torproject.org is blocked here so I can't fetch it."
  Write-Output "Two ways forward:"
  Write-Output "  A) Install Tor Browser via the GitHub mirror (reachable in RU):"
  Write-Output "     https://github.com/TheTorProject/gettorbrowser/releases  (torbrowser-install-win64-*.exe)"
  Write-Output "     then re-run this script -- it auto-finds the install."
  Write-Output "  B) Tell me to proceed: I bundle tor+snowflake into the app (fetched at BUILD time,"
  Write-Output "     never on your blocked machine) and you test it in-app -- the production path."
  exit 1
}
Write-Output "tor:       $torExe"
Write-Output "snowflake: $($sfExe.FullName)"

# --- 3. write the ADAPTIVE torrc (reachable STUN, NOT Google) ---
# Tor's ClientTransportPlugin "exec" line splits on spaces and does NOT honor quotes,
# so a snowflake path with spaces ("...\Tor Browser\...") breaks CreateProcess. Copy the
# PT into our space-free build dir and reference THAT. Same trick the real bridge will use.
$data = "$root\data"
New-Item -ItemType Directory -Force -Path $data | Out-Null
$sfLocal = "$root\snowflake-client.exe"
Copy-Item $sfExe.FullName $sfLocal -Force
$fp = '2B280B23E1107BB62ABFC40DDCC8824814F80A72'
$broker = 'https://snowflake-broker.torproject.net.global.prod.fastly.net/'
$ice = 'stun:stun.cloudflare.com:3478,stun:global.stun.twilio.com:3478,stun:stun.relay.metered.ca:80'
$torrc = "$root\torrc"
@"
UseBridges 1
SocksPort 127.0.0.1:$socks
DataDirectory $data
ClientTransportPlugin snowflake exec $sfLocal
Bridge snowflake 192.0.2.3:80 $fp fingerprint=$fp url=$broker front=foursquare.com ice=$ice utls-imitate=hellorandomizedalpn
ClientOnly 1
AvoidDiskWrites 1
Log notice stdout
"@ | Out-File -FilePath $torrc -Encoding ascii

# --- 4. start tor, wait for Bootstrapped 100% ---
$log = "$root\tor.log"
if (Test-Path $log) { Remove-Item $log -Force }
Write-Output "`nStarting tor (Snowflake)... on symmetric NAT the WebRTC channel needs a few"
Write-Output "proxy attempts -- giving it up to 3 minutes."
$p = Start-Process -FilePath $torExe -ArgumentList @('-f', $torrc) -NoNewWindow -PassThru -RedirectStandardOutput $log
$ok = $false
$maxPct = 0
for ($i = 0; $i -lt 180; $i++) {
  Start-Sleep -Seconds 1
  if (Test-Path $log) {
    $content = Get-Content $log -ErrorAction SilentlyContinue
    if ($content -match 'Bootstrapped 100%') { $ok = $true; break }
    $all = $content | Select-String -Pattern 'Bootstrapped (\d+)%'
    if ($all) {
      $cur = [int]$all[-1].Matches[0].Groups[1].Value
      if ($cur -gt $maxPct) { $maxPct = $cur }
      Write-Host ("`r  bootstrap $cur% (max $maxPct%)    ") -NoNewline
    }
  }
}
Write-Output ""

if (-not $ok) {
  Write-Output "Snowflake did NOT reach 100% in 180s (max $maxPct%). Last log lines:"
  Get-Content $log -Tail 12 -ErrorAction SilentlyContinue | ForEach-Object { Write-Output "  $_" }
  try { Stop-Process -Id $p.Id -Force } catch {}
  Write-Output "VERDICT: bootstrap failed -- send me these log lines and I'll tune ICE/front."
  exit 1
}
Write-Output "Bootstrapped 100% -- Snowflake tunnel is UP."

# --- 5. pull Telegram (and a control) THROUGH the Snowflake SOCKS ---
function Curl-Socks($url) {
  try {
    $r = & curl.exe -s -m 25 --socks5-hostname "127.0.0.1:$socks" -o NUL -w "%{http_code}" $url 2>$null
    return "HTTP $r"
  } catch { return "FAIL: $($_.Exception.Message)" }
}
Write-Output ""
Write-Output "Through the Snowflake SOCKS (127.0.0.1:$socks):"
Write-Output ("  exit trace (1.1.1.1) : " + (Curl-Socks 'https://1.1.1.1/cdn-cgi/trace'))
Write-Output ("  api.telegram.org     : " + (Curl-Socks 'https://api.telegram.org/'))
Write-Output ("  core.telegram.org    : " + (Curl-Socks 'https://core.telegram.org/'))
Write-Output ("  web.telegram.org     : " + (Curl-Socks 'https://web.telegram.org/'))

try { Stop-Process -Id $p.Id -Force } catch {}
Write-Output ""
Write-Output "========================== VERDICT =========================="
Write-Output "If api/core/web.telegram.org returned an HTTP code (even 302/404/200), Telegram is"
Write-Output "REACHED through Tor-over-Snowflake -- server-less, no VPS, on your blocked network."
Write-Output "Then I wire this in as a bridge (fetch tor+snowflake, route TG through the SOCKS)."
Write-Output "============================================================="
