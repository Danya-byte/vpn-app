# tg-flagmap.ps1 - pull the PASS-C thread. tg-ttlmap proved the hop-3 dropper is SYN-SPECIFIC:
# a SYN dies at hop 3, but a bare ACK PASSES hop 3 (exceeded @94.142.0.3) and reaches the hop-7
# injector. So non-SYN flows THROUGH the dropper. This maps the dropper's EXACT rule:
#   (1) FLAG MATRIX: TTL-walk every TCP flag combo to see which PASS hop 3 vs die there.
#       Critically includes SYN+ACK (0x12) -- NEVER tested; if the dropper matches "SYN set AND
#       ACK clear" (pure connection-init), a SYN+ACK slips it.
#   (2) REAL-DC reach: at ttl=64, does any non-SYN get a REAL DC reply (ttl>=40) vs only the
#       hop-7 injector (ttl 1-8)? A real reply = the packet reached the actual DC at hop 11.
#   (3) FORWARD-PRIMING: a full-ttl ACK first (creates injector/flow state), THEN a SYN on the
#       SAME 4-tuple -- does the now-"established" flow let the SYN pass?
# Discriminators (measured): exceeded from 94.142.0.3 or beyond = PAST the dropper; inbound from
# the DC with ttl>=40 = REAL DC packet (SYN-ACK=crack, RST=reachable); ttl<40 = hop-7 injector.
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
function FixTcp([byte[]]$p){ $ihl=($p[0]-band 0x0F)*4; $p[10]=0;$p[11]=0; $ic=Ck $p 0 $ihl 0; $p[10]=[byte](($ic -shr 8)-band 0xFF);$p[11]=[byte]($ic -band 0xFF)
  $ph=0;$ph+=(([int]$p[12]-shl 8)-bor $p[13]);$ph+=(([int]$p[14]-shl 8)-bor $p[15]);$ph+=(([int]$p[16]-shl 8)-bor $p[17]);$ph+=(([int]$p[18]-shl 8)-bor $p[19]);$ph+=6;$ph+=($p.Length-$ihl)
  $p[$ihl+16]=0;$p[$ihl+17]=0; $tc=Ck $p $ihl $p.Length $ph; $p[$ihl+16]=[byte](($tc -shr 8)-band 0xFF);$p[$ihl+17]=[byte]($tc -band 0xFF); return $p }
function FixIp([byte[]]$p){ $p[10]=0;$p[11]=0; $ic=Ck $p 0 20 0; $p[10]=[byte](($ic -shr 8)-band 0xFF);$p[11]=[byte]($ic -band 0xFF); return $p }
function Rnd(){ Get-Random -Minimum 20000 -Maximum 60000 }
# TCP packet with arbitrary flags, fixed src port (so a prime + follow-up share a 4-tuple)
function TcpF($srcIp,$dstIp,$sport,$dport,$flags,$ttl,$payload){ $pl=@(); if($payload){ $pl=@($payload) }
  $total=40+$pl.Length; $p=New-Object byte[] $total
  $p[0]=0x45;$p[2]=[byte](($total -shr 8)-band 0xFF);$p[3]=[byte]($total -band 0xFF);$p[4]=0x13;$p[5]=0x37;$p[6]=0x40;$p[8]=[byte]$ttl;$p[9]=6
  [Array]::Copy((IpB $srcIp),0,$p,12,4);[Array]::Copy((IpB $dstIp),0,$p,16,4)
  $p[20]=[byte](($sport -shr 8)-band 0xFF);$p[21]=[byte]($sport -band 0xFF);$p[22]=[byte](($dport -shr 8)-band 0xFF);$p[23]=[byte]($dport -band 0xFF)
  $p[27]=1; if(($flags -band 0x10) -ne 0){ $p[31]=1 }   # ack num set when ACK flag present
  $p[32]=0x50;$p[33]=[byte]$flags;$p[34]=0xFF;$p[35]=0xFF
  for($k=0;$k -lt $pl.Length;$k++){ $p[40+$k]=[byte]$pl[$k] }
  return (FixTcp $p) }
function IcmpEcho($srcIp,$dstIp,$ttl){ $p=New-Object byte[] 28; $p[0]=0x45;$p[3]=28;$p[4]=0x13;$p[5]=0x37;$p[6]=0x40;$p[8]=[byte]$ttl;$p[9]=1
  [Array]::Copy((IpB $srcIp),0,$p,12,4);[Array]::Copy((IpB $dstIp),0,$p,16,4); $p=FixIp $p
  $p[20]=8;$p[21]=0;$p[24]=0x13;$p[25]=0x37;$p[26]=0;$p[27]=1; $p[22]=0;$p[23]=0; $c=Ck $p 20 28 0; $p[22]=[byte](($c -shr 8)-band 0xFF);$p[23]=[byte]($c -band 0xFF); return $p }

$u=New-Object System.Net.Sockets.UdpClient;$u.Connect('1.1.1.1',53);$srcIp=$u.Client.LocalEndPoint.Address.ToString();$u.Close()
$dc='149.154.167.51'; $dcEsc=[regex]::Escape($dc); $preDropper=@('192.168.0.1','100.93.208.1')
$h=[WD]::WinDivertOpen('inbound and (icmp or tcp.SrcPort == 443)',0,0,0)
if($h.ToInt64() -eq -1){Write-Host "open fail";exit 1}
[WD]::StartRecv($h); $sa=New-Object byte[] 128;$sa[10]=0x02
function Send-P($pk){ $b=[byte[]]$pk; $sl=0; [void][WD]::WinDivertSend($h,$b,[uint32]$b.Length,[ref]$sl,$sa) }
$script:hits=@()
# walk a flag combo by TTL 2..9 + full 64; report which hops passed + any real/injector reply
function Flag($label,$flags,$payload){
  [void][WD]::Drain()
  for($t=2;$t -le 9;$t++){ Send-P (TcpF $srcIp $dc (Rnd) 443 $flags $t $payload); Start-Sleep -Milliseconds 110 }
  Send-P (TcpF $srcIp $dc (Rnd) 443 $flags 64 $payload); Start-Sleep -Milliseconds 60; Send-P (TcpF $srcIp $dc (Rnd) 443 $flags 64 $payload)
  Start-Sleep -Milliseconds 1400; Classify $label
}
function Classify($label){
  $ev=[WD]::Drain(); $hopset=@{}; $real=$null; $inj=$null
  foreach($line in $ev){
    if($line -match 'icmp=11/' -and $line -match "origdst=$dcEsc"){ if($line -match '^src=([0-9.]+) '){ $hopset[$matches[1]]=$true } }
    elseif($line -match "^src=$dcEsc "){
      $ttl=0; if($line -match 'ttl=([0-9]+)'){ $ttl=[int]$matches[1] }
      $fl=0;  if($line -match 'flags=0x([0-9A-Fa-f]{2})'){ $fl=[Convert]::ToInt32($matches[1],16) }
      if((($fl -band 0x12) -eq 0x12) -and $ttl -ge 40){ $real="SYN-ACK ttl=$ttl" }
      elseif($ttl -ge 40){ if(-not $real){ $real="DC-reply(0x$('{0:X2}' -f $fl)) ttl=$ttl" } }
      elseif(($fl -band 0x04) -ne 0){ if(-not $inj){ $inj="inj-RST ttl=$ttl" } }
    }
  }
  $hops=@($hopset.Keys); $past=@($hops | Where-Object { $preDropper -notcontains $_ }); $passed=($past.Count -gt 0)
  $hopstr = if($hops.Count){ ($hops -join ',') } else { 'none' }
  $rep = if($real){ $real } elseif($inj){ $inj } else { 'silent' }
  $tag=''; $col='Gray'
  if($real -match 'SYN-ACK'){ $tag='[CRACK]'; $col='Green' }
  elseif($real){ $tag='[REAL DC REPLY]'; $col='Green' }
  elseif($passed){ $tag='[PAST DROPPER]'; $col='Cyan' }
  Write-Host ("  {0,-22} hops:{1,-30} reply:{2,-22} {3}" -f $label,$hopstr,$rep,$tag) -ForegroundColor $col
  if($real){ $script:hits += "$label -> $real" } elseif($passed){ $script:hits += "$label -> past dropper ($hopstr)" }
}

Write-Output "src=$srcIp  dc=$dc"; Write-Output ''
Write-Output '== CALIBRATION =='
[void][WD]::Drain(); 1..3|ForEach-Object{ Send-P (IcmpEcho $srcIp $dc 64); Start-Sleep -Milliseconds 80 }; Start-Sleep -Milliseconds 900; $ce=[WD]::Drain()
$echo=@($ce|Where-Object{ $_ -match 'icmp=0/' })
Write-Host ("  ICMP echo to DC: {0}" -f $(if($echo){'REPLY -> path+DC live'}else{'NO REPLY -> void, re-run'})) -ForegroundColor $(if($echo){'Green'}else{'Red'})
Write-Output ''
Write-Output '== FLAG MATRIX through the hop-3 dropper (which flags PASS? does any reach the real DC?) =='
Flag 'SYN 0x02 (control)'   0x02 $null
Flag 'SYN+ACK 0x12 *NEW*'   0x12 $null
Flag 'ACK 0x10'             0x10 $null
Flag 'FIN 0x01'             0x01 $null
Flag 'RST 0x04'             0x04 $null
Flag 'PSH+ACK 0x18'         0x18 $null
Flag 'FIN+ACK 0x11'         0x11 $null
Flag 'NULL 0x00'            0x00 $null
Flag 'URG+ACK 0x30'         0x30 $null
Flag 'SYN+ACK+ECE+CWR 0xD2' 0xD2 $null
Flag 'ACK+data'             0x10 ([byte[]]@(0x16,0x03,0x01,0x00,0x01))
Write-Output ''
Write-Output '== FORWARD-PRIMING: full-ttl ACK first (build flow state), then SYN on the SAME 4-tuple =='
$pp=Rnd
[void][WD]::Drain()
Send-P (TcpF $srcIp $dc $pp 443 0x10 64 $null); Start-Sleep -Milliseconds 250          # prime: ACK reaches hop7 injector
for($t=2;$t -le 6;$t++){ Send-P (TcpF $srcIp $dc $pp 443 0x02 $t $null); Start-Sleep -Milliseconds 110 }  # then SYN, same tuple
Send-P (TcpF $srcIp $dc $pp 443 0x02 64 $null); Start-Sleep -Milliseconds 1400; Classify 'primed-ACK then SYN'
Write-Output ''

[WD]::Run=$false; Start-Sleep -Milliseconds 300; [void][WD]::WinDivertClose($h)
Write-Output '========================== VERDICT =========================='
if(-not $echo){ Write-Output '  Calibration dead -> void, re-run.' }
elseif(@($script:hits|Where-Object{$_ -match 'SYN-ACK|DC-reply'}).Count){ Write-Output '  BREAKTHROUGH: a packet got a REAL reply from the DC (ttl>=40) -> it reached the actual DC:'; $script:hits|Where-Object{$_ -match 'SYN-ACK|DC-reply'}|ForEach-Object{ Write-Output "    $_" }; Write-Output '  If SYN-ACK -> dial+pin. If a real RST to SYN+ACK/ACK -> the DC SEES our non-SYN; next we plant a TCB.' }
elseif($script:hits.Count){ Write-Output '  Flags that PASS the hop-3 dropper (flow past 94.142.0.3) -- the dropper is SYN-specific:'; $script:hits|ForEach-Object{ Write-Output "    $_" }; Write-Output '  None reached the REAL DC (only the hop-7 injector). Next: does non-SYN survive PAST hop 7 to the DC?' }
else { Write-Output '  Only the plain control behaved as before; nothing new passed. Re-examine the dropper model.' }
Write-Output '============================================================='
