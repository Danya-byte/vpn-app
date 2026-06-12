# webrtc-probe.ps1 - is the WebRTC / Snowflake foundation alive on THIS network?
#
# A reachable intermediate is REQUIRED to reach a blackholed IP (net4people #579: "an
# intermediate node with an IP from the whitelist is typically required"). The
# innovative, un-rentable intermediate is a Snowflake-style WebRTC volunteer proxy.
# Its plumbing is UDP/STUN (NAT traversal). This probe tests whether UDP/STUN works
# here -- if it does, the peer-mesh / Snowflake path is viable on your net.
#
# Sends a real RFC-5389 STUN Binding Request over UDP to public STUN servers and reads
# the Binding Success + your public (server-reflexive) address. Read-only, 4s timeouts.

$ErrorActionPreference = 'SilentlyContinue'

function Test-Stun($hostname, $port) {
  $udp = New-Object System.Net.Sockets.UdpClient
  try {
    $udp.Client.ReceiveTimeout = 4000
    $udp.Connect($hostname, $port)
    # STUN Binding Request: type=0x0001, len=0, magic cookie 0x2112A442, 12-byte TXID
    $txid = New-Object byte[] 12
    (New-Object System.Random).NextBytes($txid)
    $req = New-Object System.Collections.Generic.List[byte]
    $req.AddRange([byte[]](0x00,0x01,0x00,0x00,0x21,0x12,0xA4,0x42))
    $req.AddRange($txid)
    $bytes = $req.ToArray()
    [void]$udp.Send($bytes, $bytes.Length)
    $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
    $resp = $udp.Receive([ref]$ep)
    if ($resp.Length -ge 20 -and $resp[0] -eq 0x01 -and $resp[1] -eq 0x01) {
      # parse XOR-MAPPED-ADDRESS (attr 0x0020) for the public IP -- nice-to-have
      $pub = ''
      $i = 20
      while ($i + 4 -le $resp.Length) {
        $atype = ($resp[$i] -shl 8) -bor $resp[$i+1]
        $alen  = ($resp[$i+2] -shl 8) -bor $resp[$i+3]
        if ($atype -eq 0x0020 -and $alen -ge 8) {
          $fam = $resp[$i+5]
          if ($fam -eq 1) {
            $p = ($resp[$i+6] -bxor 0x21), ($resp[$i+7] -bxor 0x12)
            $o = ($resp[$i+8] -bxor 0x21), ($resp[$i+9] -bxor 0x12), ($resp[$i+10] -bxor 0xA4), ($resp[$i+11] -bxor 0x42)
            $pub = ("{0}.{1}.{2}.{3}:{4}" -f $o[0],$o[1],$o[2],$o[3], (($p[0] -shl 8) -bor $p[1]))
          }
        }
        $i += 4 + $alen
      }
      return "STUN OK" + $(if ($pub) { " (public $pub)" } else { "" })
    }
    return "bad-response"
  } catch { return "FAIL/timeout" }
  finally { try { $udp.Close() } catch {} }
}

function Test-TcpQuick($hostname, $port) {
  $c = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $c.BeginConnect($hostname, $port, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne(4000)) { $c.Close(); return 'TIMEOUT' }
    $c.EndConnect($iar); $c.Close(); return 'OPEN'
  } catch { try { $c.Close() } catch {}; return 'RST/no-route' }
}

Write-Output "================ WebRTC / Snowflake viability probe ================"
Write-Output ("admin={0}   {1}" -f ([bool]([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)), (Get-Date))
Write-Output ""
Write-Output "(1) UDP / STUN (the WebRTC NAT-traversal foundation):"
$stun = @(
  @('stun.l.google.com', 19302),
  @('stun1.l.google.com', 19302),
  @('stun.cloudflare.com', 3478),
  @('stun.relay.metered.ca', 80),
  @('global.stun.twilio.com', 3478)
)
$stunOk = $false
foreach ($s in $stun) {
  $r = Test-Stun $s[0] $s[1]
  if ($r -like 'STUN OK*') { $stunOk = $true }
  Write-Output ("  {0,-26}:{1,-6} {2}" -f $s[0], $s[1], $r)
}
Write-Output ""
Write-Output "(2) TURN/relay + Snowflake rendezvous reachability (TCP):"
$rv = @(
  @('snowflake.torproject.net', 443),
  @('snowflake-broker.torproject.net.global.prod.fastly.net', 443),
  @('turn.cloudflare.com', 443),
  @('openrelay.metered.ca', 443)
)
foreach ($h in $rv) { Write-Output ("  {0,-52}:{1} {2}" -f $h[0], $h[1], (Test-TcpQuick $h[0] $h[1])) }
Write-Output ""
Write-Output "========================== VERDICT =========================="
if ($stunOk) {
  Write-Output "UDP/STUN WORKS -> WebRTC NAT traversal is alive here -> the Snowflake / peer-mesh"
  Write-Output "intermediate is VIABLE on this network. Build it: ephemeral residential relays the"
  Write-Output "censor cannot enumerate, traffic disguised as a video call. This is the server-less,"
  Write-Output "un-rentable path to Telegram."
} else {
  Write-Output "UDP/STUN is blocked here. WebRTC-over-UDP is dead -> Snowflake would fall back to its"
  Write-Output "TCP/HTTPS rendezvous (slower) or this net is a tight whitelist. Tell me the (2) results"
  Write-Output "and whether plain UDP (e.g. WireGuard/QUIC) ever works for you, and I will adapt."
}
Write-Output "============================================================="
