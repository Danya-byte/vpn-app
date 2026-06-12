# tg-syn-evade.ps1 - the seam tg-ttlmap.ps1 exposed: the censor drops TCP-SYN to the DC
# SPECIFICALLY (ICMP reaches the DC and it replies ttl=55; a bare ACK flows to the hop-7
# RST-injector; only the SYN is killed at hop ~3). A SYN-flag dropper is often evadable if
# its match is strict (pure-SYN / :443-only). So: fire many SYN SHAPES at the DC and watch
# for a REAL reply. We measured the DC's reply ttl = ~55; the injector spoofs ttl 1-8. So the
# discriminator is rock-solid: ANY inbound from the DC with ttl >= 40 is a genuine DC packet
# -> that shape reached the DC. A real SYN-ACK (ttl>=40) = the handshake's first packet got
# through = server-less CRACK; we pin that exact shape in a client.
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
      else if(proto==1 && rl>=ihl+2){ ev+=" icmp="+pkt[ihl]+"/"+pkt[ihl+1]; }
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
# general TCP packet: flags, ttl, dst port, optional TCP options, optional payload, reserved-nibble
function TcpPkt($srcIp,$dstIp,$sport,$dport,$flags,$ttl,$opts,$payload,$resv){
  $ob=@(); if($opts){ $ob=@($opts) }; $pb=@(); if($payload){ $pb=@($payload) }
  while(($ob.Length % 4) -ne 0){ $ob=$ob + 0 }
  $tcpHdr=20+$ob.Length; $total=20+$tcpHdr+$pb.Length
  $p=New-Object byte[] $total
  $p[0]=0x45;$p[2]=[byte](($total -shr 8)-band 0xFF);$p[3]=[byte]($total -band 0xFF);$p[4]=0x13;$p[5]=0x37;$p[6]=0x40;$p[8]=[byte]$ttl;$p[9]=6
  [Array]::Copy((IpB $srcIp),0,$p,12,4);[Array]::Copy((IpB $dstIp),0,$p,16,4)
  $o=20
  $p[$o]=[byte](($sport -shr 8)-band 0xFF);$p[$o+1]=[byte]($sport -band 0xFF)
  $p[$o+2]=[byte](($dport -shr 8)-band 0xFF);$p[$o+3]=[byte]($dport -band 0xFF)
  $p[$o+7]=1
  $p[$o+12]=[byte]((([int]($tcpHdr/4)) -shl 4) -bor ([int]$resv -band 0x0F))
  $p[$o+13]=[byte]$flags
  $p[$o+14]=0xFF;$p[$o+15]=0xFF
  for($k=0;$k -lt $ob.Length;$k++){ $p[$o+20+$k]=[byte]$ob[$k] }
  for($k=0;$k -lt $pb.Length;$k++){ $p[$o+20+$ob.Length+$k]=[byte]$pb[$k] }
  return (FixTcp $p) }
function IcmpEcho($srcIp,$dstIp,$ttl){ $p=New-Object byte[] 28; $p[0]=0x45;$p[3]=28;$p[4]=0x13;$p[5]=0x37;$p[6]=0x40;$p[8]=[byte]$ttl;$p[9]=1
  [Array]::Copy((IpB $srcIp),0,$p,12,4);[Array]::Copy((IpB $dstIp),0,$p,16,4); $p=FixIp $p
  $p[20]=8;$p[21]=0;$p[24]=0x13;$p[25]=0x37;$p[26]=0;$p[27]=1; $p[22]=0;$p[23]=0; $c=Ck $p 20 28 0; $p[22]=[byte](($c -shr 8)-band 0xFF);$p[23]=[byte]($c -band 0xFF); return $p }

$u=New-Object System.Net.Sockets.UdpClient;$u.Connect('1.1.1.1',53);$srcIp=$u.Client.LocalEndPoint.Address.ToString();$u.Close()
$dc='149.154.167.51'
$h=[WD]::WinDivertOpen('inbound and ip.SrcAddr == 149.154.167.51',0,0,0)
if($h.ToInt64() -eq -1){Write-Host "open fail";exit 1}
[WD]::StartRecv($h); $sa=New-Object byte[] 128;$sa[10]=0x02
function Send-P($pk){ $b=[byte[]]$pk; $sl=0; [void][WD]::WinDivertSend($h,$b,[uint32]$b.Length,[ref]$sl,$sa) }
function Rnd(){ Get-Random -Minimum 20000 -Maximum 60000 }
$script:crack=@(); $script:reached=@()
# fire a shape (optionally a $pre decoy first, same flow), classify the DC's response by ttl
function Probe($label,$pk,$pre){
  [void][WD]::Drain()
  for($i=0;$i -lt 3;$i++){ if($pre){ Send-P $pre; Start-Sleep -Milliseconds 20 }; Send-P $pk; Start-Sleep -Milliseconds 60 }
  Start-Sleep -Milliseconds 1300; $ev=[WD]::Drain()
  $real=$null; $inj=$null
  foreach($line in $ev){
    if($line -notmatch 'proto=6'){ continue }
    $ttl=0; if($line -match 'ttl=([0-9]+)'){ $ttl=[int]$matches[1] }
    $fl=0;  if($line -match 'flags=0x([0-9A-Fa-f]{2})'){ $fl=[Convert]::ToInt32($matches[1],16) }
    $isSynAck=(($fl -band 0x12) -eq 0x12); $isRst=(($fl -band 0x04) -ne 0)
    if($ttl -ge 40){ if($isSynAck -and -not $real){ $real="SYN-ACK ttl=$ttl flags=0x$('{0:X2}' -f $fl)" } elseif($isRst -and -not $real){ $real="real-RST ttl=$ttl" } }
    elseif($isRst -and -not $inj){ $inj="injected-RST ttl=$ttl" }
  }
  if($real -match 'SYN-ACK'){ Write-Host ("  [CRACK!] {0,-30} {1}" -f $label,$real) -ForegroundColor Green; $script:crack+="$label -> $real" }
  elseif($real){ Write-Host ("  [DC hit] {0,-30} {1}  (reached DC; that port/shape refused)" -f $label,$real) -ForegroundColor Cyan; $script:reached+="$label -> $real" }
  elseif($inj){ Write-Host ("  [block]  {0,-30} {1}" -f $label,$inj) -ForegroundColor DarkYellow }
  else        { Write-Host ("  [drop]   {0,-30} silent" -f $label) -ForegroundColor Gray }
}

Write-Output "src=$srcIp  dc=$dc"; Write-Output ''
Write-Output '== CALIBRATION (path + DC must be live this run) =='
[void][WD]::Drain(); 1..3|ForEach-Object{ Send-P (IcmpEcho $srcIp $dc 64); Start-Sleep -Milliseconds 80 }; Start-Sleep -Milliseconds 1000; $ev=[WD]::Drain()
$echo=@($ev|Where-Object{ $_ -match 'icmp=0/' })
Write-Host ("  ICMP echo to DC: {0}" -f $(if($echo){"REPLY ($($echo[0])) -> path+DC live"}else{'NO REPLY -> path dead, results void'})) -ForegroundColor $(if($echo){'Green'}else{'Red'})
Write-Output ''

$opts=[byte[]]@(0x02,0x04,0x05,0xB4, 0x01, 0x03,0x03,0x08, 0x01,0x01, 0x04,0x02)   # MSS,NOP,WScale,NOP,NOP,SACKperm
Write-Output '== SYN-SHAPE battery on :443 (slip a SYN past the flag-dropper) =='
Probe 'pure SYN 0x02 (control)'   (TcpPkt $srcIp $dc (Rnd) 443 0x02 64 $null $null 0)
Probe 'SYN+ECE+CWR 0xC2'          (TcpPkt $srcIp $dc (Rnd) 443 0xC2 64 $null $null 0)
Probe 'SYN+CWR 0x82'              (TcpPkt $srcIp $dc (Rnd) 443 0x82 64 $null $null 0)
Probe 'SYN+ECE 0x42'              (TcpPkt $srcIp $dc (Rnd) 443 0x42 64 $null $null 0)
Probe 'SYN+reserved-nibble 0x0E'  (TcpPkt $srcIp $dc (Rnd) 443 0x02 64 $null $null 0x0E)
Probe 'SYN +full TCP options'     (TcpPkt $srcIp $dc (Rnd) 443 0x02 64 $opts $null 0)
Probe 'SYN+ECE+CWR +options'      (TcpPkt $srcIp $dc (Rnd) 443 0xC2 64 $opts $null 0)
Probe 'SYN +4B data'              (TcpPkt $srcIp $dc (Rnd) 443 0x02 64 $null ([byte[]]@(0x16,0x03,0x01,0x00)) 0)
Probe 'SYN+PSH 0x0A'              (TcpPkt $srcIp $dc (Rnd) 443 0x0A 64 $null $null 0)
Probe 'SYN+FIN 0x03'             (TcpPkt $srcIp $dc (Rnd) 443 0x03 64 $null $null 0)
Write-Output ''

Write-Output '== ALTERNATE DC PORTS (maybe the dropper only watches :443) =='
foreach($pt in @(80,5222,2095,8443,993)){
  Probe ("pure SYN :$pt")       (TcpPkt $srcIp $dc (Rnd) $pt 0x02 64 $null $null 0)
}
Probe 'SYN+ECE+CWR :80'          (TcpPkt $srcIp $dc (Rnd) 80 0xC2 64 $opts $null 0)
Write-Output ''

Write-Output '== STATE-DESYNC combos (decoy dies at the dropper, real SYN follows, same flow) =='
$p1=Rnd; Probe 'decoy SYN(ttl3) + real SYN' (TcpPkt $srcIp $dc $p1 443 0x02 64 $null $null 0) (TcpPkt $srcIp $dc $p1 443 0x02 3 $null $null 0)
$p2=Rnd; Probe 'decoy RST(ttl3) + real SYN' (TcpPkt $srcIp $dc $p2 443 0x02 64 $null $null 0) (TcpPkt $srcIp $dc $p2 443 0x04 3 $null $null 0)
$p3=Rnd; Probe 'decoy SYN(ttl5) + real SYN' (TcpPkt $srcIp $dc $p3 443 0x02 64 $null $null 0) (TcpPkt $srcIp $dc $p3 443 0x02 5 $null $null 0)
Write-Output ''

[WD]::Run=$false; Start-Sleep -Milliseconds 300; [void][WD]::WinDivertClose($h)
Write-Output '========================== VERDICT =========================='
if(-not $echo){ Write-Output '  Calibration dead -> path/DC unreachable this run; results void, re-run.' }
elseif($script:crack.Count){ Write-Output '  CRACK: a SYN shape got a REAL SYN-ACK from the DC (ttl>=40). The handshake first packet'; Write-Output '  slipped the dropper. I pin this EXACT shape in a client and we are server-less on Telegram:'; $script:crack|ForEach-Object{ Write-Output "    $_" } }
elseif($script:reached.Count){ Write-Output '  PARTIAL CRACK: a shape REACHED the DC (real response, ttl>=40) -> the dropper IS evadable;'; Write-Output '  the DC saw us, that port/shape just refused. Next iteration tunes shape/port to get a SYN-ACK:'; $script:reached|ForEach-Object{ Write-Output "    $_" } }
else { Write-Output '  No shape elicited a real DC response (all silent or injector-RST ttl<40). The SYN-dropper'; Write-Output '  matches every variant tried -> the SYN-flag match is robust, not a strict pure-SYN/:443 rule.'; Write-Output '  That closes the flag-evasion seam; the drop is broad. (Still SYN-specific, not dst-IP.)' }
Write-Output '============================================================='
