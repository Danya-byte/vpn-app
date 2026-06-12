# tg-windivert-decoy.ps1 - OUR OWN WinDivert packet crafter (what zapret/winws cannot do).
#
# The middlebox drops TCP where (proto==TCP AND dst in Telegram-CIDR), keyed on the IP
# header. winws couldn't touch the SYN. So we craft RAW SYNs ourselves via WinDivert and
# test whether IP-OPTIONS / SOURCE-ROUTING make the box mis-classify or mis-parse:
#   1 baseline   : plain SYN to a DC            (confirms inject works + baseline drop)
#   2 tg+LSRR    : dst=DC, loose-source-route option [1.1.1.1] (box may read the option)
#   3 tg+RR      : dst=DC, record-route option   (does ANY IP option confuse the parser?)
#   4 tg+unknown : dst=DC, unknown IP option     (parser-ambiguity)
#   5 LSRR-decoy : dst=1.1.1.1 (ALLOWED) + LSRR final=DC (box sees allowed dst; a router
#                  that honors source-routing would forward to the DC -- pure decoy)
# A real INBOUND SYN-ACK sniffed FROM a Telegram IP after any variant = CRACKED, direct,
# server-less. (Replies are filtered to Telegram src only, so 1.1.1.1 self-replies don't
# false-positive.) Caveat: home router/CGNAT may drop IP-options packets before the box,
# making option-variants inconclusive -- but if one returns, it's a genuine crack.
#
# RUN AS ADMINISTRATOR, app FULLY CLOSED.

$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host 'ERROR: run AS ADMINISTRATOR (WinDivert driver).' -ForegroundColor Red; exit 1
}
$cw = Join-Path (Split-Path $PSScriptRoot -Parent) 'core\windows'
if (-not (Test-Path (Join-Path $cw 'WinDivert.dll'))) { Write-Host "WinDivert.dll not found in $cw" -ForegroundColor Red; exit 1 }
[Environment]::CurrentDirectory = $cw
$env:PATH = "$cw;$env:PATH"

# WinDivert.dll is loaded IN this process via P/Invoke, so its bitness must match the
# PowerShell process. WinDivert64.sys -> the DLL is 64-bit; if we're 32-bit, relaunch.
$dllBytes = [System.IO.File]::ReadAllBytes((Join-Path $cw 'WinDivert.dll'))
$peOff = [BitConverter]::ToInt32($dllBytes, 0x3C)
$dll64 = ([BitConverter]::ToUInt16($dllBytes, $peOff + 4) -eq 0x8664)
if ($dll64 -ne [Environment]::Is64BitProcess -and -not $env:TG_WD_RELAUNCH) {
  $env:TG_WD_RELAUNCH = '1'
  $bit = if ($dll64) { '64' } else { '32' }
  $alt = if ($dll64) { Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe' }
         else { Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe' }
  Write-Host "WinDivert.dll is $bit-bit, this PowerShell is not -- relaunching $bit-bit PowerShell..." -ForegroundColor Yellow
  if (Test-Path $alt) { & $alt -ExecutionPolicy Bypass -File $PSCommandPath; exit $LASTEXITCODE }
  Write-Host "Could not find $bit-bit powershell.exe ($alt). Launch the script with that PowerShell manually." -ForegroundColor Red
  exit 1
}

$cs = @'
using System; using System.Runtime.InteropServices; using System.Threading;
public static class WD {
  [DllImport("WinDivert.dll", CharSet=CharSet.Ansi, SetLastError=true)]
  public static extern IntPtr WinDivertOpen(string filter, int layer, short priority, ulong flags);
  [DllImport("WinDivert.dll", SetLastError=true)]
  public static extern bool WinDivertSend(IntPtr h, byte[] p, uint len, out uint sendLen, byte[] addr);
  [DllImport("WinDivert.dll", SetLastError=true)]
  public static extern bool WinDivertRecv(IntPtr h, byte[] p, uint len, out uint recvLen, byte[] addr);
  [DllImport("WinDivert.dll", SetLastError=true)]
  public static extern bool WinDivertClose(IntPtr h);
  [DllImport("WinDivert.dll", SetLastError=true)]
  public static extern bool WinDivertHelperCalcChecksums(byte[] p, uint len, byte[] addr, ulong flags);
  public static volatile bool Got=false; public static volatile string GotSrc="";
  public static void RecvLoop(IntPtr h){
    byte[] pkt=new byte[2048]; byte[] addr=new byte[128]; uint rlen;
    while(true){ if(!WinDivertRecv(h,pkt,(uint)pkt.Length,out rlen,addr)) break;
      if(rlen>=20){ GotSrc=pkt[12]+"."+pkt[13]+"."+pkt[14]+"."+pkt[15]; Got=true; } } }
  public static void StartRecv(IntPtr h){ var t=new Thread(()=>RecvLoop(h)); t.IsBackground=true; t.Start(); }
}
'@
Add-Type -TypeDefinition $cs

function Build-Syn($srcIp, $dstIp, $srcPort, [byte[]]$opts) {
  if (-not $opts) { $opts = @() }
  $opts = @($opts)
  while ($opts.Count % 4 -ne 0) { $opts += [byte]0 }
  $ihl = 5 + [int]($opts.Count / 4)
  $hdr = $ihl * 4
  $tot = $hdr + 20
  $p = New-Object byte[] $tot
  $p[0] = [byte](0x40 -bor $ihl); $p[1] = 0
  $p[2] = [byte](($tot -shr 8) -band 0xFF); $p[3] = [byte]($tot -band 0xFF)
  $p[4] = 0x13; $p[5] = 0x37; $p[6] = 0; $p[7] = 0; $p[8] = 64; $p[9] = 6
  [Array]::Copy(([System.Net.IPAddress]::Parse($srcIp)).GetAddressBytes(), 0, $p, 12, 4)
  [Array]::Copy(([System.Net.IPAddress]::Parse($dstIp)).GetAddressBytes(), 0, $p, 16, 4)
  if ($opts.Count -gt 0) { [Array]::Copy($opts, 0, $p, 20, $opts.Count) }
  $t = $hdr
  $p[$t] = [byte](($srcPort -shr 8) -band 0xFF); $p[$t+1] = [byte]($srcPort -band 0xFF)
  $p[$t+2] = 0x01; $p[$t+3] = 0xBB   # dst port 443
  $p[$t+7] = 1                        # seq=1
  $p[$t+12] = 0x50; $p[$t+13] = 0x02  # data-offset 5, SYN
  $p[$t+14] = 0xFF; $p[$t+15] = 0xFF  # window
  return $p
}
function Opt-Lsrr($ips) { $b = @([byte]0x83, [byte](3 + 4*$ips.Count), [byte]4); foreach ($ip in $ips) { $b += ([System.Net.IPAddress]::Parse($ip)).GetAddressBytes() }; return [byte[]]$b }
function Opt-Rr($n)     { $b = @([byte]0x07, [byte](3 + 4*$n), [byte]4); for ($i=0;$i -lt 4*$n;$i++){ $b += [byte]0 }; return [byte[]]$b }
function Opt-Unknown()  { return [byte[]]@(0x9F, 0x04, 0x00, 0x00) }

# our local source IP (so a reply NATs back to us)
$u = New-Object System.Net.Sockets.UdpClient; $u.Connect('1.1.1.1', 53); $srcIp = $u.Client.LocalEndPoint.Address.ToString(); $u.Close()
$dc = '149.154.167.51'
Write-Output "src=$srcIp  dc=$dc"

# reply sniff: inbound SYN-ACK from 1.1.1.1 (CONTROL: proves the crafter works) OR Telegram.
$filter = 'inbound and tcp.SrcPort == 443 and (' +
  'ip.SrcAddr == 1.1.1.1 or ' +
  '(ip.SrcAddr >= 149.154.160.0 and ip.SrcAddr <= 149.154.175.255) or ' +
  '(ip.SrcAddr >= 91.108.4.0 and ip.SrcAddr <= 91.108.59.255) or ' +
  '(ip.SrcAddr >= 95.161.64.0 and ip.SrcAddr <= 95.161.79.255))'
$h = [WD]::WinDivertOpen($filter, 0, 0, 0)
if ($h.ToInt64() -eq -1) { Write-Host "WinDivertOpen failed (err $([Runtime.InteropServices.Marshal]::GetLastWin32Error())). Is the driver blocked?" -ForegroundColor Red; exit 1 }
[WD]::StartRecv($h)

$sendAddr = New-Object byte[] 128; $sendAddr[10] = 0x02   # Outbound bit (layer NETWORK, event 0)
$variants = @(
  @{ n = '0 CONTROL 1.1.1.1'; opts = $null;                   dst = '1.1.1.1' },
  @{ n = '1 baseline';        opts = $null;                   dst = $dc },
  @{ n = '2 tg+LSRR';         opts = (Opt-Lsrr @('1.1.1.1')); dst = $dc },
  @{ n = '3 tg+RR';           opts = (Opt-Rr 2);              dst = $dc },
  @{ n = '4 tg+unknown';      opts = (Opt-Unknown);           dst = $dc },
  @{ n = '5 LSRR-decoy';      opts = (Opt-Lsrr @($dc));       dst = '1.1.1.1' }
)
$controlOk = $false; $cracked = ''
Write-Output ''
foreach ($v in $variants) {
  [WD]::Got = $false; [WD]::GotSrc = ''
  $sent = $false
  for ($k = 0; $k -lt 3; $k++) {
    $sp = Get-Random -Minimum 20000 -Maximum 60000
    $pkt = Build-Syn $srcIp $v.dst $sp $v.opts
    [void][WD]::WinDivertHelperCalcChecksums($pkt, [uint32]$pkt.Length, $sendAddr, 0)
    try { $sl = 0; if ([WD]::WinDivertSend($h, $pkt, [uint32]$pkt.Length, [ref]$sl, $sendAddr)) { $sent = $true } } catch {}
    Start-Sleep -Milliseconds 200
  }
  Start-Sleep -Milliseconds 1500
  if ([WD]::Got) {
    $src = [WD]::GotSrc
    Write-Host ("  {0,-20} SYN-ACK from {1}" -f $v.n, $src) -ForegroundColor Green
    if ($src -eq '1.1.1.1') { $controlOk = $true } else { $cracked = "$($v.n) <- $src" }
  } else {
    $tag = if ($sent) { 'sent, no reply' } else { 'SEND FAILED' }
    Write-Host ("  {0,-20} {1}" -f $v.n, $tag) -ForegroundColor Gray
  }
}
Start-Sleep -Milliseconds 500
[void][WD]::WinDivertClose($h)
Write-Output ''
Write-Output "========================== VERDICT =========================="
if ($cracked) {
  Write-Output "CRACKED: $cracked -- an IP-options/source-route SYN reached a Telegram DC and it"
  Write-Output "answered. Direct server-less route exists; I build a WinDivert transport around it."
} elseif ($controlOk) {
  Write-Output "Crafter VALIDATED (control 1.1.1.1 replied with SYN-ACK) -> the injector + checksums"
  Write-Output "work. So Telegram's total silence is REAL: the dst-IP ACL is airtight at the IP layer,"
  Write-Output "no pure-packet trick remains, an intermediate is genuinely required. Bedrock."
} else {
  Write-Output "Even the 1.1.1.1 CONTROL got no reply -> my injector/checksum is the problem, NOT proof"
  Write-Output "of the block. The Telegram result is INVALID until the crafter works. I fix the crafter"
  Write-Output "(likely WinDivertSend addr/IfIdx or checksum flags) and we retest. Send me this output."
}
Write-Output "============================================================="
