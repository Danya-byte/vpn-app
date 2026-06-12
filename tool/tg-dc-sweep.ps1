# tg-dc-sweep.ps1 - we only ever tested ONE Telegram DC IP (149.154.167.51). Telegram has
# 5 DCs + media + CDN across dozens of IPs. The block is a SYN-drop, NOT a full IP-blackhole
# (ICMP round-trips to the DC, proven). A SYN-drop need not cover every TG IP uniformly. So:
# fire a real SYN at a BROAD set of real Telegram DC/media IPs x ports {443,80,5222} and look
# for ANY that answers. Discriminator (battle-measured): a real DC reply has ttl ~50-57; the
# hop-7 injector spoofs ttl 1-8. So ANY inbound from a TG IP with ttl>=40 is a REAL packet:
#   SYN-ACK ttl>=40 = OPEN endpoint -> connect/pin it (server-less Telegram).
#   RST     ttl>=40 = the IP is REACHABLE, that port just closed -> SYN is NOT dropped there,
#                     sweep more ports on it. THAT alone breaks the "all TG SYN dropped" claim.
#   RST     ttl<40  = the hop-7 injector (blocked).   silent = SYN dropped at hop ~3.
#
# RUN AS ADMINISTRATOR, app CLOSED. Self-relaunches to 64-bit. No internet, no 3rd-party tool.

$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Write-Host 'run AS ADMIN' -ForegroundColor Red; exit 1 }
$cw = Join-Path (Split-Path $PSScriptRoot -Parent) 'core\windows'
[Environment]::CurrentDirectory = $cw; $env:PATH = "$cw;$env:PATH"
$dbf = [System.IO.File]::ReadAllBytes((Join-Path $cw 'WinDivert.dll'))
$dll64 = ([BitConverter]::ToUInt16($dbf, [BitConverter]::ToInt32($dbf, 0x3C) + 4) -eq 0x8664)
if ($dll64 -ne [Environment]::Is64BitProcess -and -not $env:TG_WD_RELAUNCH) {
  $env:TG_WD_RELAUNCH = '1'; $alt = if ($dll64) { Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe' } else { Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe' }
  Write-Host 'relaunching 64-bit PowerShell...' -ForegroundColor Yellow
  if (Test-Path $alt) { & $alt -ExecutionPolicy Bypass -File $PSCommandPath; exit $LASTEXITCODE }; exit 1
}
$cs = @'
using System; using System.Runtime.InteropServices; using System.Threading; using System.Collections.Generic;
public static class WD {
  [DllImport("WinDivert.dll", CharSet=CharSet.Ansi, SetLastError=true)] public static extern IntPtr WinDivertOpen(string f, int l, short p, ulong fl);
  [DllImport("WinDivert.dll", SetLastError=true)] public static extern bool WinDivertSend(IntPtr h, byte[] p, uint n, out uint s, byte[] a);
  [DllImport("WinDivert.dll", SetLastError=true)] public static extern bool WinDivertRecv(IntPtr h, byte[] p, uint n, out uint r, byte[] a);
  [DllImport("WinDivert.dll", SetLastError=true)] public static extern bool WinDivertClose(IntPtr h);
  public static List<string> Log=new List<string>(); public static volatile bool Run=true;
  public static void RecvLoop(IntPtr h){ byte[] pkt=new byte[2048]; byte[] addr=new byte[128]; uint rl;
    while(Run){ if(!WinDivertRecv(h,pkt,(uint)pkt.Length,out rl,addr)) break; if(rl<20) continue;
      int ihl=(pkt[0]&0x0F)*4; int proto=pkt[9]; string src=pkt[12]+"."+pkt[13]+"."+pkt[14]+"."+pkt[15];
      string ev="src="+src+" ttl="+pkt[8]+" proto="+proto;
      if(proto==6 && rl>=ihl+14){ ev+=" sport="+((pkt[ihl]<<8)|pkt[ihl+1])+" flags=0x"+pkt[ihl+13].ToString("X2"); }
      lock(Log){ Log.Add(ev); } } }
  public static void StartRecv(IntPtr h){ var t=new Thread(()=>RecvLoop(h)); t.IsBackground=true; t.Start(); }
  public static string[] Drain(){ lock(Log){ var a=Log.ToArray(); Log.Clear(); return a; } }
}
'@
Add-Type -TypeDefinition $cs
function IpB($ip){ return ([System.Net.IPAddress]::Parse($ip)).GetAddressBytes() }
function Ck($p,$s,$e,$seed){ $sum=$seed; for($i=$s;$i -lt $e;$i+=2){ $lo=0; if($i+1 -lt $e){$lo=$p[$i+1]}; $sum+=(([int]$p[$i]-shl 8)-bor [int]$lo) }; while($sum -shr 16){$sum=($sum -band 0xFFFF)+($sum -shr 16)}; return ((-bnot $sum)-band 0xFFFF) }
function FixTcp([byte[]]$p){ $ihl=($p[0]-band 0x0F)*4; $p[10]=0;$p[11]=0; $ic=Ck $p 0 $ihl 0; $p[10]=[byte](($ic -shr 8)-band 0xFF);$p[11]=[byte]($ic -band 0xFF)
  $ph=0;$ph+=(([int]$p[12]-shl 8)-bor $p[13]);$ph+=(([int]$p[14]-shl 8)-bor $p[15]);$ph+=(([int]$p[16]-shl 8)-bor $p[17]);$ph+=(([int]$p[18]-shl 8)-bor $p[19]);$ph+=6;$ph+=($p.Length-$ihl)
  $p[$ihl+16]=0;$p[$ihl+17]=0; $tc=Ck $p $ihl $p.Length $ph; $p[$ihl+16]=[byte](($tc -shr 8)-band 0xFF);$p[$ihl+17]=[byte]($tc -band 0xFF); return $p }
# realistic SYN (full TCP options like a real OS) to maximize a real reply if the IP is reachable
function SynPkt($srcIp,$dstIp,$sport,$dport){ $opt=@(0x02,0x04,0x05,0xB4,0x01,0x03,0x03,0x08,0x01,0x01,0x04,0x02); $p=New-Object byte[] 52
  $p[0]=0x45;$p[2]=0;$p[3]=52;$p[4]=0x13;$p[5]=0x37;$p[6]=0x40;$p[8]=64;$p[9]=6
  [Array]::Copy((IpB $srcIp),0,$p,12,4);[Array]::Copy((IpB $dstIp),0,$p,16,4)
  $p[20]=[byte](($sport -shr 8)-band 0xFF);$p[21]=[byte]($sport -band 0xFF);$p[22]=[byte](($dport -shr 8)-band 0xFF);$p[23]=[byte]($dport -band 0xFF)
  $p[27]=1;$p[32]=0x80;$p[33]=0x02;$p[34]=0xFF;$p[35]=0xFF
  for($k=0;$k -lt $opt.Length;$k++){ $p[40+$k]=[byte]$opt[$k] }
  return (FixTcp $p) }

$u=New-Object System.Net.Sockets.UdpClient;$u.Connect('1.1.1.1',53);$srcIp=$u.Client.LocalEndPoint.Address.ToString();$u.Close()
$h=[WD]::WinDivertOpen('inbound and (tcp.SrcPort == 443 or tcp.SrcPort == 80 or tcp.SrcPort == 5222 or tcp.SrcPort == 1)',0,0,0)
if($h.ToInt64() -eq -1){Write-Host "open fail";exit 1}
[WD]::StartRecv($h); $sa=New-Object byte[] 128;$sa[10]=0x02
function Send-P($pk){ $b=[byte[]]$pk; $sl=0; [void][WD]::WinDivertSend($h,$b,[uint32]$b.Length,[ref]$sl,$sa) }
function Rnd(){ Get-Random -Minimum 20000 -Maximum 60000 }

# Real Telegram DC + media/CDN IPs (the addresses the desktop client actually dials), spread
# across all 5 DCs and the media ranges, plus a few per-/22 samples to widen coverage.
$dcIps = @(
  '149.154.175.50','149.154.175.51','149.154.175.52','149.154.175.100',   # DC1 / DC3
  '149.154.167.50','149.154.167.51','149.154.167.91','149.154.167.41',     # DC2 / DC4
  '149.154.171.5','149.154.171.50','149.154.171.100','149.154.165.120',    # DC5 / extra
  '149.154.160.1','149.154.162.1','149.154.164.1','149.154.166.1','149.154.168.1','149.154.172.1',
  '91.108.56.130','91.108.56.165','91.108.4.5','91.108.8.5','91.108.12.5','91.108.16.5','91.108.20.5',
  '95.161.76.100','185.76.151.1')
$ports = @(443,80,5222)
$tgset = @{}; foreach($ip in $dcIps){ $tgset[$ip]=$true }

Write-Output "src=$srcIp   targets=$($dcIps.Count) IPs x $($ports.Count) ports = $($dcIps.Count*$ports.Count) probes"
Write-Output ''
Write-Output '== CALIBRATION =='
[void][WD]::Drain(); 1..3|ForEach-Object{ Send-P (SynPkt $srcIp '1.1.1.1' (Rnd) 443); Start-Sleep -Milliseconds 80 }; Start-Sleep -Milliseconds 1000; $ev=[WD]::Drain()
$c1=@($ev|Where-Object{ $_ -match '^src=1\.1\.1\.1 ' -and $_ -match 'flags=0x12' })
Write-Host ("  SYN->1.1.1.1:443 : {0}" -f $(if($c1){"SYN-ACK ($($c1[0])) -> crafter live"}else{'NO REPLY -> crafter/driver broken, results void'})) -ForegroundColor $(if($c1){'Green'}else{'Red'})
Write-Output ''

Write-Output '== BROAD Telegram DC/media SYN sweep =='
[void][WD]::Drain()
foreach($ip in $dcIps){ foreach($pt in $ports){ Send-P (SynPkt $srcIp $ip (Rnd) $pt); Start-Sleep -Milliseconds 18 } }
Start-Sleep -Milliseconds 3500; $ev=[WD]::Drain()

$open=@(); $rrst=@(); $inj=@{}
foreach($line in $ev){
  if($line -notmatch '^src=([0-9.]+) ' ){ continue }; $s=$matches[1]
  if(-not $tgset.ContainsKey($s)){ continue }
  $ttl=0; if($line -match 'ttl=([0-9]+)'){ $ttl=[int]$matches[1] }
  $sp=0;  if($line -match 'sport=([0-9]+)'){ $sp=[int]$matches[1] }
  $fl=0;  if($line -match 'flags=0x([0-9A-Fa-f]{2})'){ $fl=[Convert]::ToInt32($matches[1],16) }
  $isSA=(($fl -band 0x12) -eq 0x12); $isRst=(($fl -band 0x04) -ne 0)
  if($isSA -and $ttl -ge 40){ $open += "$s`:$sp  ttl=$ttl" }
  elseif($isRst -and $ttl -ge 40){ $rrst += "$s`:$sp  ttl=$ttl" }
  elseif($isRst){ $inj["$s`:$sp"]=$ttl }
}
$open=@($open|Select-Object -Unique); $rrst=@($rrst|Select-Object -Unique)
if($open.Count){ Write-Host '  OPEN Telegram endpoint(s) (real SYN-ACK, ttl>=40):' -ForegroundColor Green; $open|ForEach-Object{ Write-Host "    $_" -ForegroundColor Green } }
if($rrst.Count){ Write-Host '  REACHABLE Telegram IP(s) (real RST ttl>=40 = IP up, port closed -> SYN NOT dropped here):' -ForegroundColor Cyan; $rrst|ForEach-Object{ Write-Host "    $_" -ForegroundColor Cyan } }
if($inj.Count){ Write-Host ("  injector-RST (ttl<40, blocked): {0} endpoints" -f $inj.Count) -ForegroundColor DarkYellow }
$silent = ($dcIps.Count*$ports.Count) - $open.Count - $rrst.Count - $inj.Count
Write-Host ("  silent (SYN dropped): ~$silent of $($dcIps.Count*$ports.Count)") -ForegroundColor Gray
Write-Output ''

[WD]::Run=$false; Start-Sleep -Milliseconds 300; [void][WD]::WinDivertClose($h)
Write-Output '========================== VERDICT =========================='
if(-not $c1){ Write-Output '  Calibration dead -> results void, re-run.' }
elseif($open.Count){ Write-Output '  WIN: a Telegram MTProto endpoint answered a raw SYN with a REAL SYN-ACK. The SYN-drop does'; Write-Output '  NOT cover it. Next: complete a real handshake to it + pin it as a server-less Telegram route.' }
elseif($rrst.Count){ Write-Output '  LEAD: Telegram IP(s) are REACHABLE (real RST, ttl>=40) on some endpoint -> the SYN is NOT'; Write-Output '  universally dropped. Next: sweep ALL ports on those reachable IPs to find an OPEN one.' }
else { Write-Output '  Every sampled TG IP/port: silent or injector-RST. The SYN-drop covers this whole sample.'; Write-Output '  Next (no give-up): passively WATCH the real Telegram Desktop (no VPN) to capture which IP/port'; Write-Output '  IT reaches, and a SLOW-trickle SYN test (rate-limited dropper may pass spaced SYNs).' }
Write-Output '============================================================='
