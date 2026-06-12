# tg-ttlmap.ps1 - localize the Telegram censor with TTL geometry, and answer the ONE
# question every server-less idea hinges on: is our SYN dropped OUTBOUND (the DC never
# sees it) or does it reach the DC and the SYN-ACK is dropped INBOUND?
#
# Method: walk TTL 1..14 to a real DC with three protocols and watch what comes back per hop:
#   - ICMP-echo  = the TRUE path map (the control: how far packets physically travel)
#   - TCP-SYN    = where the SYN dies
#   - TCP-ACK    = where the RST-injector sits (it injects on non-SYN; ttl of the RST = its hop)
# A router emits ICMP-TTL-Exceeded when ttl hits 0; a policy-DROP middlebox stays SILENT.
# So: if SYN stops yielding Exceeded at hop ~6 while ICMP keeps going to hop ~11 -> the
# middlebox drops TCP-SYN OUTBOUND (DC never sees us; server-less is physically sealed).
# If SYN yields Exceeded as far as ICMP (hop ~10-11) but no SYN-ACK returns -> our packets
# REACH the DC and only the return is filtered = a genuine seam to work the return channel.
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
function SynPkt($srcIp,$dstIp,$sp,$ttl){ $p=New-Object byte[] 40; $p[0]=0x45;$p[3]=40;$p[4]=0x13;$p[5]=0x37;$p[6]=0x40;$p[8]=[byte]$ttl;$p[9]=6
  [Array]::Copy((IpB $srcIp),0,$p,12,4);[Array]::Copy((IpB $dstIp),0,$p,16,4)
  $p[20]=[byte](($sp -shr 8)-band 0xFF);$p[21]=[byte]($sp -band 0xFF);$p[22]=0x01;$p[23]=0xBB;$p[27]=1;$p[32]=0x50;$p[33]=0x02;$p[34]=0xFF;$p[35]=0xFF; return (FixTcp $p) }
function AckPkt($srcIp,$dstIp,$sp,$ttl){ $p=New-Object byte[] 40; $p[0]=0x45;$p[3]=40;$p[4]=0x13;$p[5]=0x37;$p[6]=0x40;$p[8]=[byte]$ttl;$p[9]=6
  [Array]::Copy((IpB $srcIp),0,$p,12,4);[Array]::Copy((IpB $dstIp),0,$p,16,4)
  $p[20]=[byte](($sp -shr 8)-band 0xFF);$p[21]=[byte]($sp -band 0xFF);$p[22]=0x01;$p[23]=0xBB;$p[27]=1;$p[31]=1;$p[32]=0x50;$p[33]=0x10;$p[34]=0xFF;$p[35]=0xFF; return (FixTcp $p) }
function IcmpEcho($srcIp,$dstIp,$ttl){ $p=New-Object byte[] 28; $p[0]=0x45;$p[3]=28;$p[4]=0x13;$p[5]=0x37;$p[6]=0x40;$p[8]=[byte]$ttl;$p[9]=1
  [Array]::Copy((IpB $srcIp),0,$p,12,4);[Array]::Copy((IpB $dstIp),0,$p,16,4); $p=FixIp $p
  $p[20]=8;$p[21]=0;$p[24]=0x13;$p[25]=0x37;$p[26]=0;$p[27]=1; $p[22]=0;$p[23]=0; $c=Ck $p 20 28 0; $p[22]=[byte](($c -shr 8)-band 0xFF);$p[23]=[byte]($c -band 0xFF); return $p }

$u=New-Object System.Net.Sockets.UdpClient;$u.Connect('1.1.1.1',53);$srcIp=$u.Client.LocalEndPoint.Address.ToString();$u.Close()
$dc='149.154.167.51'; $dcEsc=[regex]::Escape($dc)
$h=[WD]::WinDivertOpen('inbound and (icmp or tcp.SrcPort == 443)',0,0,0)
if($h.ToInt64() -eq -1){Write-Host "open fail";exit 1}
[WD]::StartRecv($h); $sa=New-Object byte[] 128;$sa[10]=0x02
function Send-P($pk){ $b=[byte[]]$pk; $sl=0; [void][WD]::WinDivertSend($h,$b,[uint32]$b.Length,[ref]$sl,$sa) }
function Rnd(){ Get-Random -Minimum 20000 -Maximum 60000 }
# classify a drained batch for a probe to the DC at one TTL
function Classify($ev,$dc,$dcEsc){
  $hop=$null; $rep=$null
  foreach($line in $ev){
    if($line -match 'icmp=11/' -and $line -match "origdst=$dcEsc"){ if($line -match '^src=([0-9.]+) '){ $hop=$matches[1] } }
    elseif($line -match 'icmp=3/' -and $line -match "origdst=$dcEsc"){ $rep="UNREACH ($line)" }
    elseif($line -match "^src=$dcEsc " -and $line -match 'icmp=0/'){ $rep="ECHO-REPLY ($line)" }
    elseif($line -match "^src=$dcEsc " -and $line -match 'flags=0x12'){ $rep="SYN-ACK ($line)" }
    elseif($line -match "^src=$dcEsc " -and ($line -match 'flags=0x04' -or $line -match 'flags=0x14')){ $rep="RST ($line)" }
  }
  if($rep){ return @{kind='reply';txt=$rep} } elseif($hop){ return @{kind='exceeded';txt="exceeded -> hop=$hop"} } else { return @{kind='silent';txt='silent'} }
}
function Walk($name,$mk){
  Write-Host "== $name =="
  $maxHop=0; $dcReply=''
  for($T=1;$T -le 14;$T++){
    [void][WD]::Drain(); Send-P (& $mk $T); Send-P (& $mk $T); Start-Sleep -Milliseconds 750; $ev=[WD]::Drain()
    $c=Classify $ev $dc $dcEsc
    if($c.kind -eq 'exceeded'){ $maxHop=$T }
    if($c.kind -eq 'reply' -and -not $dcReply){ $dcReply=$c.txt }
    $col=if($c.kind -eq 'reply'){'Green'}elseif($c.kind -eq 'exceeded'){'Gray'}else{'DarkYellow'}
    Write-Host ("  ttl={0,-2} {1}" -f $T,$c.txt) -ForegroundColor $col
  }
  Write-Host ''
  return @{maxHop=$maxHop;reply=$dcReply}
}

Write-Output "src=$srcIp  dc=$dc"; Write-Output ''
$A = Walk 'PASS A: ICMP-echo TTL walk (TRUE path = control)'  { param($T) IcmpEcho $srcIp $dc $T }
$B = Walk 'PASS B: TCP-SYN  TTL walk (where the SYN dies)'    { param($T) SynPkt  $srcIp $dc (Rnd) $T }
$C = Walk 'PASS C: TCP-ACK  TTL walk (where the RST-injector sits)' { param($T) AckPkt $srcIp $dc (Rnd) $T }

[WD]::Run=$false; Start-Sleep -Milliseconds 300; [void][WD]::WinDivertClose($h)
Write-Output '========================== VERDICT =========================='
Write-Output ("  ICMP reached/last-hop: {0}{1}" -f $A.maxHop, $(if($A.reply){"  (DC replied: $($A.reply))"}else{''}))
Write-Output ("  SYN  last TTL-exceeded hop: {0}{1}" -f $B.maxHop, $(if($B.reply){"  (DC replied: $($B.reply))"}else{''}))
Write-Output ("  ACK  last TTL-exceeded hop: {0}{1}" -f $C.maxHop, $(if($C.reply){"  (DC replied: $($C.reply))"}else{''}))
Write-Output ''
if($A.maxHop -eq 0 -and -not $A.reply){ Write-Output '  Control DID NOT map any hops -> environment/driver issue, results void.' }
elseif($B.reply -match 'SYN-ACK'){ Write-Output '  SYN-ACK returned from the DC -> the DC is REACHABLE. Pin it in a client.' }
elseif($B.maxHop -ge ($A.maxHop-1) -and $A.maxHop -gt 0){ Write-Output '  SEAM: the SYN travels as far as ICMP (reaches the DC vicinity) but no SYN-ACK comes back ->' ; Write-Output '  our packets REACH the DC and only the RETURN path is filtered. Next script works the return channel.' }
else { Write-Output ('  SYN is swallowed near hop {0} while ICMP travels to hop {1} -> the middlebox drops TCP-SYN' -f ($B.maxHop+1), $A.maxHop) ; Write-Output '  OUTBOUND (protocol-specific). The DC never sees our SYN; server-less is physically sealed here.' }
Write-Output '============================================================='
