# tg-portscope.ps1 - the ONE axis never tested: the dst PORT. Every SYN test so far hit 443/80/5222
# -- exactly the MTProto ports the dropper watches. Question this answers: is the hop-3 dropper
# keyed on dst-IP ALONE (drops SYN to the DC on every port) or dst-IP+PORT (drops only the known
# ports)? If port-keyed, a SYN to the DC on an UNWATCHED port slips hop 3 and reaches the DC, which
# answers RST (port closed) ttl~55 -- proving the SYN GOT THERE = a real, detectable breakthrough.
# A SYN is dropped at hop 3 BEFORE the hop-7 injector, so any reply here is the REAL DC (no TTL
# reflection to fool us). Discriminator: inbound from the DC, ttl>=40 -> reached the DC.
#   SYN-ACK ttl>=40 = an OPEN port (MTProto-capable -> pin it).  RST ttl>=40 = SYN reached DC, port
#   closed, but the dropper did NOT block that port -> the dropper is PORT-scoped (the gap).
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
function Rnd(){ Get-Random -Minimum 20000 -Maximum 60000 }
function SynPkt($srcIp,$dstIp,$dport){ $opt=@(0x02,0x04,0x05,0xB4,0x01,0x03,0x03,0x08,0x01,0x01,0x04,0x02); $p=New-Object byte[] 52
  $p[0]=0x45;$p[3]=52;$p[4]=0x13;$p[5]=0x37;$p[6]=0x40;$p[8]=64;$p[9]=6
  [Array]::Copy((IpB $srcIp),0,$p,12,4);[Array]::Copy((IpB $dstIp),0,$p,16,4); $sp=Rnd
  $p[20]=[byte](($sp -shr 8)-band 0xFF);$p[21]=[byte]($sp -band 0xFF);$p[22]=[byte](($dport -shr 8)-band 0xFF);$p[23]=[byte]($dport -band 0xFF)
  $p[27]=1;$p[32]=0x80;$p[33]=0x02;$p[34]=0xFF;$p[35]=0xFF; for($k=0;$k -lt $opt.Length;$k++){ $p[40+$k]=[byte]$opt[$k] }; return (FixTcp $p) }

$u=New-Object System.Net.Sockets.UdpClient;$u.Connect('1.1.1.1',53);$srcIp=$u.Client.LocalEndPoint.Address.ToString();$u.Close()
$dc='149.154.167.51'; $dcEsc=[regex]::Escape($dc); $cu='1.1.1.1'; $cuEsc=[regex]::Escape($cu)
$h=[WD]::WinDivertOpen("inbound and (ip.SrcAddr == $dc or ip.SrcAddr == $cu)",0,0,0)
if($h.ToInt64() -eq -1){Write-Host "open fail";exit 1}
[WD]::StartRecv($h); $sa=New-Object byte[] 128;$sa[10]=0x02
function Send-P($pk){ $b=[byte[]]$pk; $sl=0; [void][WD]::WinDivertSend($h,$b,[uint32]$b.Length,[ref]$sl,$sa) }

# watched MTProto ports (controls, expect silent) + many UNWATCHED candidates
$ports=@(443,80,5222, 22,53,123,143,179,194,443,465,587,636,853,990,993,995,1080,1194,1701,1723,
  2052,2053,2082,2083,2086,2087,2095,2096,3128,3389,5223,5228,5269,6667,8080,8443,8888,9000,9001,
  9443,10000,12345,33434,49152,51820,54321,65000)
$ports=@($ports | Select-Object -Unique)
Write-Output "src=$srcIp  dc=$dc  ports=$($ports.Count)"
Write-Output ''
Write-Output '== CALIBRATION =='
[void][WD]::Drain(); 1..3|ForEach-Object{ Send-P (SynPkt $srcIp $cu 443); Start-Sleep -Milliseconds 80 }; Start-Sleep -Milliseconds 1000; $ev=[WD]::Drain()
$c1=@($ev|Where-Object{ $_ -match "^src=$cuEsc " -and $_ -match 'flags=0x12' })
Write-Host ("  SYN->1.1.1.1:443 : {0}" -f $(if($c1){"SYN-ACK -> crafter live"}else{'NO REPLY -> void'})) -ForegroundColor $(if($c1){'Green'}else{'Red'})
Write-Output ''
Write-Output '== PORT SCOPE: SYN to the DC across many ports (does an UNWATCHED port reach the DC?) =='
[void][WD]::Drain()
foreach($pt in $ports){ Send-P (SynPkt $srcIp $dc $pt); Start-Sleep -Milliseconds 40 }
Start-Sleep -Milliseconds 4000; $ev=[WD]::Drain()
$open=@(); $reach=@()
foreach($line in $ev){
  if($line -notmatch "^src=$dcEsc "){ continue }
  $ttl=0; if($line -match 'ttl=([0-9]+)'){ $ttl=[int]$matches[1] }
  $sp=0;  if($line -match 'sport=([0-9]+)'){ $sp=[int]$matches[1] }
  $fl=0;  if($line -match 'flags=0x([0-9A-Fa-f]{2})'){ $fl=[Convert]::ToInt32($matches[1],16) }
  if($ttl -lt 40){ continue }   # (SYN has no hop-7 injector reflection, but keep the guard)
  if(($fl -band 0x12) -eq 0x12){ $open += "port $sp  SYN-ACK ttl=$ttl" }
  elseif(($fl -band 0x04) -ne 0){ $reach += "port $sp  RST ttl=$ttl" }
}
$open=@($open|Select-Object -Unique); $reach=@($reach|Select-Object -Unique)
if($open.Count){ Write-Host '  OPEN port(s) on the DC (SYN-ACK!) -> MTProto-capable, PIN IT:' -ForegroundColor Green; $open|ForEach-Object{ Write-Host "    $_" -ForegroundColor Green } }
if($reach.Count){ Write-Host '  SYN REACHED the DC (real RST ttl>=40) -> dropper is PORT-scoped, these ports are NOT blocked:' -ForegroundColor Cyan; $reach|ForEach-Object{ Write-Host "    $_" -ForegroundColor Cyan } }
if(-not $open.Count -and -not $reach.Count){ Write-Host '  every port silent' -ForegroundColor Gray }
Write-Output ''
[WD]::Run=$false; Start-Sleep -Milliseconds 300; [void][WD]::WinDivertClose($h)
Write-Output '========================== VERDICT =========================='
if(-not $c1){ Write-Output '  Calibration dead -> void, re-run.' }
elseif($open.Count){ Write-Output '  BREAKTHROUGH: a DC port answered SYN-ACK -> the dropper missed it. Complete the handshake + pin.' }
elseif($reach.Count){ Write-Output '  REAL BREAKTHROUGH (small but real): SYN REACHED the DC on an unwatched port (real RST, ttl>=40).'; Write-Output '  The dropper is PORT-scoped, NOT pure dst-IP. Next: find a port the DC SERVES that it does not watch.' }
else { Write-Output '  Every port silent -> the dropper is dst-IP-keyed (drops SYN to the DC on ALL ports), not port-scoped.'; Write-Output '  That is itself a clean detected fact. Next: passive watch of the real Telegram client + the hop-7'; Write-Output '  injector exploitation angle (it is a live, reflecting middlebox we can probe further).' }
Write-Output '============================================================='
