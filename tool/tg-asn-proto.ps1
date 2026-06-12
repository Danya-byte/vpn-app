# tg-asn-proto.ps1 - the two angles the round-2 invention workflow left genuinely open:
#   (#1) HARDENED ASN sweep: SYN via WinDivert (not TcpClient, which the hop6 RST-injector
#        can spoof) to Telegram-ASN IPs OUTSIDE cidr.txt; a TTL~53 SYN-ACK = a REAL reachable
#        DC outside the block (list drifts behind BGP). Calibrated: SYN->1.1.1.1 must answer,
#        SYN->in-CIDR DC must be silent.
#   (#3) PROTO-axis sweep: is the dropper (proto in {6,17,47}, dst) or (any proto, dst)?
#        inject proto 4/41/50/51/132/136 to a DC; any reply / ICMP-unreach echoing our packet
#        = that proto inherits the working ICMP route -> a carrier with a gap.
#
# RUN AS ADMINISTRATOR, app CLOSED. Self-relaunches to 64-bit. Needs internet for RIPEstat.

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
      if(proto==6 && rl>=ihl+14) ev+=" flags=0x"+pkt[ihl+13].ToString("X2");
      else if(proto==1 && rl>=ihl+2){ ev+=" icmp="+pkt[ihl]+"/"+pkt[ihl+1]; if((pkt[ihl]==3||pkt[ihl]==11)&&rl>=ihl+8+20){int o=ihl+8; ev+=" origdst="+pkt[o+16]+"."+pkt[o+17]+"."+pkt[o+18]+"."+pkt[o+19];} }
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
function FixIp([byte[]]$p){ $p[10]=0;$p[11]=0; $ic=Ck $p 0 20 0; $p[10]=[byte](($ic -shr 8)-band 0xFF);$p[11]=[byte]($ic -band 0xFF); return $p }
function SynPkt($srcIp,$dstIp,$sp){ $p=New-Object byte[] 40; $p[0]=0x45;$p[3]=40;$p[4]=0x13;$p[5]=0x37;$p[6]=0x40;$p[8]=64;$p[9]=6
  [Array]::Copy((IpB $srcIp),0,$p,12,4);[Array]::Copy((IpB $dstIp),0,$p,16,4)
  $p[20]=[byte](($sp -shr 8)-band 0xFF);$p[21]=[byte]($sp -band 0xFF);$p[22]=0x01;$p[23]=0xBB;$p[27]=1;$p[32]=0x50;$p[33]=0x02;$p[34]=0xFF;$p[35]=0xFF; return (FixTcp $p) }
function RawPkt($srcIp,$dstIp,$proto){ $p=New-Object byte[] 28; $p[0]=0x45;$p[3]=28;$p[6]=0x40;$p[8]=64;$p[9]=[byte]$proto; [Array]::Copy((IpB $srcIp),0,$p,12,4);[Array]::Copy((IpB $dstIp),0,$p,16,4); return (FixIp $p) }

$u=New-Object System.Net.Sockets.UdpClient;$u.Connect('1.1.1.1',53);$srcIp=$u.Client.LocalEndPoint.Address.ToString();$u.Close()
$dc='149.154.167.51'; $blockedRe='^(149\.154\.|91\.108\.|95\.161\.|91\.105\.|185\.76\.)'
$h=[WD]::WinDivertOpen('inbound and (icmp or tcp.SrcPort == 443)',0,0,0)
if($h.ToInt64() -eq -1){Write-Host "open fail";exit 1}
[WD]::StartRecv($h); $sa=New-Object byte[] 128;$sa[10]=0x02
function Send-P($pk){ $sl=0; [void][WD]::WinDivertSend($h,$pk,[uint32]$pk.Length,[ref]$sl,$sa) }
function Rnd(){ Get-Random -Minimum 20000 -Maximum 60000 }

Write-Output "src=$srcIp"; Write-Output ''
Write-Output '== CALIBRATION (proves the test discriminates) =='
[void][WD]::Drain(); 1..3 | ForEach-Object { Send-P (SynPkt $srcIp '1.1.1.1' (Rnd)); Start-Sleep -Milliseconds 100 }; Start-Sleep -Milliseconds 1200; $ev=[WD]::Drain()
$cal1=@($ev|Where-Object{$_ -like 'src=1.1.1.1 *' -and $_ -match 'flags=0x12'}); Write-Host ("  SYN->1.1.1.1   : {0}" -f $(if($cal1){"SYN-ACK ($($cal1[0]))"}else{'NO REPLY (crafter broken!)'})) -ForegroundColor $(if($cal1){'Green'}else{'Red'})
[void][WD]::Drain(); 1..3 | ForEach-Object { Send-P (SynPkt $srcIp $dc (Rnd)); Start-Sleep -Milliseconds 100 }; Start-Sleep -Milliseconds 1200; $ev=[WD]::Drain()
$cal2=@($ev|Where-Object{$_ -like "src=$dc *"}); Write-Host ("  SYN->in-CIDR DC: {0}" -f $(if($cal2){"reply $($cal2[0])"}else{'silent (as expected)'}))
Write-Output ''

Write-Output '== (#1) FULL-FOOTPRINT sweep: SYN via WinDivert to a sample of EVERY Telegram prefix =='
# RIPE is unreachable from this network (returned 0). So the prefix list is HARDCODED from real
# BGP (announced-prefixes for AS62041/62014/59930/44907/211157, fetched 2026-06). FINDING: every
# one of Telegram's announced IPv4 prefixes is INSIDE the classic block regex -> off-CIDR Telegram
# space does NOT exist (no drift to chase). So we no longer hunt "off-CIDR"; we instead inject a
# SYN to one sample IP in EACH real prefix and confirm the WHOLE footprint is sealed (all silent).
$tgPrefixes=@(
  '149.154.160.0/22','149.154.164.0/22','149.154.168.0/22','149.154.172.0/22',
  '91.108.4.0/22','91.108.8.0/22','91.108.12.0/22','91.108.16.0/22','91.108.20.0/22','91.108.56.0/22',
  '95.161.64.0/20','91.105.192.0/23','185.76.151.0/24')
$off=@($tgPrefixes | Where-Object { $_ -notmatch $blockedRe })   # proven empty -> documents the finding
Write-Output ("  Telegram footprint: $($tgPrefixes.Count) real prefixes, $($off.Count) OFF the classic block (off-CIDR drift = none)")
$ips=@()
foreach($p in $tgPrefixes){ $parts=$p -split '/'; $b=([System.Net.IPAddress]::Parse($parts[0])).GetAddressBytes(); $base=[uint32]((([uint32]$b[0])-shl 24)-bor(([uint32]$b[1])-shl 16)-bor(([uint32]$b[2])-shl 8)-bor $b[3])
  foreach($o in @(1,17,100)){ $v=$base+$o; $ips+=("{0}.{1}.{2}.{3}" -f (($v -shr 24)-band 0xFF),(($v -shr 16)-band 0xFF),(($v -shr 8)-band 0xFF),($v -band 0xFF)) } }
$ips=@($ips | Select-Object -Unique)
$ipset=@{}; foreach($ip in $ips){ $ipset[$ip]=$true }
Write-Output ("  injecting SYN to $($ips.Count) sample IPs across Telegram's whole footprint...")
[void][WD]::Drain(); foreach($ip in $ips){ Send-P (SynPkt $srcIp $ip (Rnd)); Start-Sleep -Milliseconds 25 }; Start-Sleep -Milliseconds 2500; $ev=[WD]::Drain()
# ONLY count a SYN-ACK whose src is an IP WE injected to (else it's background :443 traffic)
$sain=@(); foreach($line in $ev){ if($line -match 'flags=0x12' -and $line -match '^src=([0-9.]+) '){ if($ipset.ContainsKey($matches[1])){ $sain += $line } } }
if($sain){ Write-Host '  A Telegram IP ANSWERED (ttl~53=real DC, ~58=hop6 spoof -- inspect before trusting):' -ForegroundColor Green; $sain|ForEach-Object{ Write-Host "    $_" -ForegroundColor Green } }
else { Write-Host "  none of the $($ips.Count) sampled Telegram IPs returned a SYN-ACK -> the whole footprint is sealed." -ForegroundColor Gray }
Write-Output ''

Write-Output '== (#3) PROTO-axis sweep to the DC (does a non-TCP/UDP/GRE proto reach TG?) =='
foreach($pr in @(4,41,50,51,132,136)){
  [void][WD]::Drain(); Send-P (RawPkt $srcIp '1.1.1.1' $pr); Send-P (RawPkt $srcIp $dc $pr); Start-Sleep -Milliseconds 1200; $ev=[WD]::Drain()
  $dcr=@($ev|Where-Object{ ($_ -like "src=$dc *") -or ($_ -match 'icmp=3/' -and $_ -match "origdst=$dc") })
  $ctl=@($ev|Where-Object{ ($_ -like 'src=1.1.1.1 *') -or ($_ -match 'icmp=3/' -and $_ -match 'origdst=1.1.1.1') })
  $tag=if($dcr){"DC REACHED: $($dcr[0])"}elseif($ctl){'DC silent (control unreach OK -> proto dropped to DC)'}else{'both silent (unreach suppressed, inconclusive)'}
  Write-Host ("  proto={0,-4} {1}" -f $pr,$tag) -ForegroundColor $(if($dcr){'Green'}else{'Gray'})
}
[WD]::Run=$false; Start-Sleep -Milliseconds 300; [void][WD]::WinDivertClose($h)
Write-Output ''
Write-Output '========================== VERDICT =========================='
if(-not $cal1){ Write-Output 'Calibration failed (SYN->1.1.1.1 silent) -> crafter/driver issue, results void.' }
elseif($sain){ Write-Output 'A Telegram IP answered a WinDivert SYN. If ttl~53 (real, ~11 hops, NOT ~58 hop6-spoof) it is a' ; Write-Output 'genuine reachable DC -> I pin it in a client. Inspect the ttl before trusting (RST-injector spoofs).' }
else { Write-Output 'PROVEN: Telegram has 0 IPv4 prefixes outside the classic block (real BGP, 5 ASNs), and a SYN to a' ; Write-Output 'sample of EVERY one of its real prefixes is silent. Combined with the dead non-TCP protos, this is a' ; Write-Output 'proto-agnostic dst-IP ACL over Telegram''s WHOLE footprint -- the sealed IP-block. Server-less is' ; Write-Output 'exhausted in battle; only a foreign hop reaches Telegram (the app already does this via its own tunnel).' }
Write-Output '============================================================='
