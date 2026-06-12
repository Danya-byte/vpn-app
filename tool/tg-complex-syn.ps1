# tg-complex-syn.ps1 - the axis we never fired: COMPLEX / multi-layer SYNs + TTL geometry.
# The hop-3 dropper classifies "SYN to TG" by the TCP-flags byte at a fixed offset. Bend the
# packet's STRUCTURE so a shallow inline parser mis-locates the flags (sees non-SYN) while the
# real router/DC parse it correctly:
#   - IP OPTIONS (Router-Alert / Record-Route / Timestamp / NOP-pad / unknown type / max-pad):
#     each raises IHL and SHIFTS the TCP header. A DPI hardcoding TCP@offset-20 reads garbage.
#   - IP-in-IP (proto 4) encapsulation: an inner SYN wrapped so the outer looks non-TCP.
# For EACH variant we TTL-walk 2..6 to see WHICH HOP it reaches (does it pass hop 3 where a
# plain SYN dies?), then a full ttl=64 send to catch a real DC reply. Discriminators (measured):
#   exceeded from 94.142.0.3 (hop3) or beyond = the variant SLIPPED the dropper's SYN classifier.
#   inbound from the DC with ttl>=40 = a REAL DC packet (SYN-ACK=crack, RST=reachable); ttl<40 = injector.
# Plain SYN is the control: it dies at hop ~2-3 (no exceeded past hop2, no reply).
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
      if(proto==6 && rl>=ihl+14){ ev+=" flags=0x"+pkt[ihl+13].ToString("X2"); }
      else if(proto==1 && rl>=ihl+2){ ev+=" icmp="+pkt[ihl]+"/"+pkt[ihl+1]; if((pkt[ihl]==3||pkt[ihl]==11)&&rl>=ihl+8+20){int o=ihl+8; ev+=" origdst="+pkt[o+16]+"."+pkt[o+17]+"."+pkt[o+18]+"."+pkt[o+19];} }
      lock(Log){ Log.Add(ev); } } }
  public static void StartRecv(IntPtr h){ var t=new Thread(()=>RecvLoop(h)); t.IsBackground=true; t.Start(); }
  public static string[] Drain(){ lock(Log){ var a=Log.ToArray(); Log.Clear(); return a; } }
}
'@
Add-Type -TypeDefinition $cs
function IpB($ip){ return ([System.Net.IPAddress]::Parse($ip)).GetAddressBytes() }
function Ck($p,$s,$e,$seed){ $sum=$seed; for($i=$s;$i -lt $e;$i+=2){ $lo=0; if($i+1 -lt $e){$lo=$p[$i+1]}; $sum+=(([int]$p[$i]-shl 8)-bor [int]$lo) }; while($sum -shr 16){$sum=($sum -band 0xFFFF)+($sum -shr 16)}; return ((-bnot $sum)-band 0xFFFF) }
# FixTcp derives IHL from p[0], so it checksums correctly WITH IP options (variable IHL).
function FixTcp([byte[]]$p){ $ihl=($p[0]-band 0x0F)*4; $p[10]=0;$p[11]=0; $ic=Ck $p 0 $ihl 0; $p[10]=[byte](($ic -shr 8)-band 0xFF);$p[11]=[byte]($ic -band 0xFF)
  $ph=0;$ph+=(([int]$p[12]-shl 8)-bor $p[13]);$ph+=(([int]$p[14]-shl 8)-bor $p[15]);$ph+=(([int]$p[16]-shl 8)-bor $p[17]);$ph+=(([int]$p[18]-shl 8)-bor $p[19]);$ph+=6;$ph+=($p.Length-$ihl)
  $p[$ihl+16]=0;$p[$ihl+17]=0; $tc=Ck $p $ihl $p.Length $ph; $p[$ihl+16]=[byte](($tc -shr 8)-band 0xFF);$p[$ihl+17]=[byte]($tc -band 0xFF); return $p }
function FixIp([byte[]]$p){ $p[10]=0;$p[11]=0; $ic=Ck $p 0 20 0; $p[10]=[byte](($ic -shr 8)-band 0xFF);$p[11]=[byte]($ic -band 0xFF); return $p }
function Rnd(){ Get-Random -Minimum 20000 -Maximum 60000 }
# plain IP(20)+TCP(20) SYN
function SynPlain($srcIp,$dstIp,$dport,$ttl){ $p=New-Object byte[] 40; $p[0]=0x45;$p[3]=40;$p[4]=0x13;$p[5]=0x37;$p[6]=0x40;$p[8]=[byte]$ttl;$p[9]=6
  [Array]::Copy((IpB $srcIp),0,$p,12,4);[Array]::Copy((IpB $dstIp),0,$p,16,4); $sp=Rnd
  $p[20]=[byte](($sp -shr 8)-band 0xFF);$p[21]=[byte]($sp -band 0xFF);$p[22]=[byte](($dport -shr 8)-band 0xFF);$p[23]=[byte]($dport -band 0xFF)
  $p[27]=1;$p[32]=0x50;$p[33]=0x02;$p[34]=0xFF;$p[35]=0xFF; return (FixTcp $p) }
# IP(20+opts)+TCP(20) SYN -- IP options raise IHL and shift the TCP header
function SynOpt($srcIp,$dstIp,$dport,$ttl,$ipopts){ $ob=@(); if($ipopts){ $ob=@($ipopts) }
  while(($ob.Length % 4) -ne 0){ $ob=$ob + 0 }
  $ihl=20+$ob.Length; $total=$ihl+20; $p=New-Object byte[] $total
  $p[0]=[byte](0x40 -bor (([int]($ihl/4)) -band 0x0F))
  $p[2]=[byte](($total -shr 8)-band 0xFF);$p[3]=[byte]($total -band 0xFF);$p[4]=0x13;$p[5]=0x37;$p[6]=0x40;$p[8]=[byte]$ttl;$p[9]=6
  [Array]::Copy((IpB $srcIp),0,$p,12,4);[Array]::Copy((IpB $dstIp),0,$p,16,4)
  for($k=0;$k -lt $ob.Length;$k++){ $p[20+$k]=[byte]$ob[$k] }
  $o=$ihl; $sp=Rnd
  $p[$o]=[byte](($sp -shr 8)-band 0xFF);$p[$o+1]=[byte]($sp -band 0xFF);$p[$o+2]=[byte](($dport -shr 8)-band 0xFF);$p[$o+3]=[byte]($dport -band 0xFF)
  $p[$o+7]=1;$p[$o+12]=0x50;$p[$o+13]=0x02;$p[$o+14]=0xFF;$p[$o+15]=0xFF; return (FixTcp $p) }
# outer IP(proto 4) wrapping a full inner SYN packet
function IpInIp($srcIp,$dstIp,$dport,$ttl){ $inner=SynPlain $srcIp $dstIp $dport 64; $total=20+$inner.Length; $p=New-Object byte[] $total
  $p[0]=0x45;$p[2]=[byte](($total -shr 8)-band 0xFF);$p[3]=[byte]($total -band 0xFF);$p[4]=0x13;$p[5]=0x37;$p[6]=0x40;$p[8]=[byte]$ttl;$p[9]=4
  [Array]::Copy((IpB $srcIp),0,$p,12,4);[Array]::Copy((IpB $dstIp),0,$p,16,4)
  for($k=0;$k -lt $inner.Length;$k++){ $p[20+$k]=[byte]$inner[$k] }; return (FixIp $p) }
function IcmpEcho($srcIp,$dstIp,$ttl){ $p=New-Object byte[] 28; $p[0]=0x45;$p[3]=28;$p[4]=0x13;$p[5]=0x37;$p[6]=0x40;$p[8]=[byte]$ttl;$p[9]=1
  [Array]::Copy((IpB $srcIp),0,$p,12,4);[Array]::Copy((IpB $dstIp),0,$p,16,4); $p=FixIp $p
  $p[20]=8;$p[21]=0;$p[24]=0x13;$p[25]=0x37;$p[26]=0;$p[27]=1; $p[22]=0;$p[23]=0; $c=Ck $p 20 28 0; $p[22]=[byte](($c -shr 8)-band 0xFF);$p[23]=[byte]($c -band 0xFF); return $p }

$u=New-Object System.Net.Sockets.UdpClient;$u.Connect('1.1.1.1',53);$srcIp=$u.Client.LocalEndPoint.Address.ToString();$u.Close()
$dc='149.154.167.51'; $dcEsc=[regex]::Escape($dc); $preDropper=@('192.168.0.1','100.93.208.1')
$h=[WD]::WinDivertOpen('inbound and (icmp or tcp.SrcPort == 443)',0,0,0)
if($h.ToInt64() -eq -1){Write-Host "open fail";exit 1}
[WD]::StartRecv($h); $sa=New-Object byte[] 128;$sa[10]=0x02
function Send-P($pk){ $b=[byte[]]$pk; $sl=0; [void][WD]::WinDivertSend($h,$b,[uint32]$b.Length,[ref]$sl,$sa) }
$script:win=@()
function Probe($label,$mk){
  [void][WD]::Drain()
  for($t=2;$t -le 6;$t++){ Send-P (& $mk $t); Start-Sleep -Milliseconds 130 }
  Send-P (& $mk 64); Start-Sleep -Milliseconds 60; Send-P (& $mk 64)
  Start-Sleep -Milliseconds 1500; $ev=[WD]::Drain()
  $hopset=@{}; $real=$null; $inj=$null
  foreach($line in $ev){
    if($line -match 'icmp=11/' -and $line -match "origdst=$dcEsc"){ if($line -match '^src=([0-9.]+) '){ $hopset[$matches[1]]=$true } }
    elseif($line -match "^src=$dcEsc "){
      $ttl=0; if($line -match 'ttl=([0-9]+)'){ $ttl=[int]$matches[1] }
      $fl=0;  if($line -match 'flags=0x([0-9A-Fa-f]{2})'){ $fl=[Convert]::ToInt32($matches[1],16) }
      if($line -match 'icmp=0/'){ if(-not $real){ $real='ECHO-REPLY' } }
      elseif((($fl -band 0x12) -eq 0x12) -and $ttl -ge 40){ $real="SYN-ACK ttl=$ttl" }
      elseif((($fl -band 0x04) -ne 0) -and $ttl -ge 40){ if(-not $real){ $real="real-RST ttl=$ttl" } }
      elseif(($fl -band 0x04) -ne 0){ if(-not $inj){ $inj="inj-RST ttl=$ttl" } }
    }
  }
  $hops=@($hopset.Keys)
  $past=@($hops | Where-Object { $preDropper -notcontains $_ })
  $passed = ($past.Count -gt 0)
  $hopstr = if($hops.Count){ ($hops -join ',') } else { 'none' }
  $rep = if($real){ $real } elseif($inj){ $inj } else { 'silent' }
  $tag = if($real -match 'SYN-ACK|real-RST'){ '[DC REACHED]' } elseif($passed){ '[PAST DROPPER]' } else { '' }
  $col = if($real -match 'SYN-ACK|real-RST'){ 'Green' } elseif($passed){ 'Cyan' } else { 'Gray' }
  Write-Host ("  {0,-26} hops:{1,-26} reply:{2,-16} {3}" -f $label,$hopstr,$rep,$tag) -ForegroundColor $col
  if($real -match 'SYN-ACK|real-RST'){ $script:win += "$label -> $real" }
  elseif($passed){ $script:win += "$label -> past dropper (hops $hopstr)" }
}

Write-Output "src=$srcIp  dc=$dc"; Write-Output ''
Write-Output '== CALIBRATION =='
[void][WD]::Drain(); 1..3|ForEach-Object{ Send-P (IcmpEcho $srcIp $dc 64); Start-Sleep -Milliseconds 80 }; Start-Sleep -Milliseconds 1000; $ev=[WD]::Drain()
$echo=@($ev|Where-Object{ $_ -match 'icmp=0/' })
Write-Host ("  ICMP echo to DC: {0}" -f $(if($echo){"REPLY -> path+DC live"}else{'NO REPLY -> path dead, results void'})) -ForegroundColor $(if($echo){'Green'}else{'Red'})
Write-Output ''
$nop36=@(); 1..35|ForEach-Object{ $nop36 += 0x01 }; $nop36 += 0x00
Write-Output '== COMPLEX / multi-layer SYN battery (TTL-walk 2..6 + full ttl=64) =='
Probe 'plain SYN (control)'        { param($t) SynPlain $srcIp $dc 443 $t }
Probe 'ipopt NOP*3+EOL (IHL6)'     { param($t) SynOpt $srcIp $dc 443 $t @(0x01,0x01,0x01,0x00) }
Probe 'ipopt NOP*35 (IHL14 maxshift)' { param($t) SynOpt $srcIp $dc 443 $t $nop36 }
Probe 'ipopt Router-Alert'         { param($t) SynOpt $srcIp $dc 443 $t @(0x94,0x04,0x00,0x00) }
Probe 'ipopt Record-Route'         { param($t) SynOpt $srcIp $dc 443 $t @(0x07,0x07,0x04,0x00,0x00,0x00,0x00) }
Probe 'ipopt Timestamp'            { param($t) SynOpt $srcIp $dc 443 $t @(0x44,0x0C,0x05,0x00,0,0,0,0,0,0,0,0) }
Probe 'ipopt unknown-type 0x1E'    { param($t) SynOpt $srcIp $dc 443 $t @(0x1E,0x04,0x00,0x00) }
Probe 'ipopt EOL-first +junk'      { param($t) SynOpt $srcIp $dc 443 $t @(0x00,0x44,0x07,0x01) }
Probe 'IP-in-IP wrapped SYN'       { param($t) IpInIp $srcIp $dc 443 $t }
Write-Output ''

[WD]::Run=$false; Start-Sleep -Milliseconds 300; [void][WD]::WinDivertClose($h)
Write-Output '========================== VERDICT =========================='
if(-not $echo){ Write-Output '  Calibration dead -> results void, re-run.' }
elseif($script:win.Count){ Write-Output '  LEAD(S) -- a complex SYN behaved DIFFERENTLY from the plain control:'; $script:win|ForEach-Object{ Write-Output "    $_" }; Write-Output '  If it REACHED the DC -> dial it for real + pin. If it only PAST-DROPPER -> the structure'; Write-Output '  slips the SYN classifier; tune the option so the DC still accepts it (gets a SYN-ACK).' }
else { Write-Output '  Every complex/multi-layer SYN died exactly like the plain control (<=hop2, no reply).'; Write-Output '  The dropper is NOT a shallow fixed-offset parser -- it tracks IHL or drops IP-options/proto-4'; Write-Output '  outright (CGNAT also strips options). Next: slow-trickle (rate test) + passive Telegram-Desktop watch.' }
Write-Output '============================================================='
