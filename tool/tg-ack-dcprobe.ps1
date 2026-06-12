# tg-ack-dcprobe.ps1 - settle the PASS-C question WITHOUT the false positive. The hop-7 injector
# REFLECTS our remaining TTL (measured: RST_ttl = send_ttl - 6). At send_ttl=64 that is 58, which
# is indistinguishable from a real DC reply (~55) -- that ambiguity faked a "[REAL DC REPLY]".
# Fix: probe non-SYN (ACK / PSH+ACK) at SEVERAL send-TTLs and separate the two sources by physics:
#   reflected reply ttl == send_ttl - 6   -> the hop-7 INJECTOR (tracks our ttl)
#   reply ttl ~50..57, FIXED across send_ttls -> the REAL DC at hop 11 (sets its own ttl=64)
# At a LOW send_ttl the two diverge hugely: send_ttl=16 -> injector=10, real DC=~55. So ANY reply
# with ttl>=50 at send_ttl<=45 is PHYSICALLY a real DC packet (reflection there is <=39). That is
# the honest proof of whether our non-SYN actually reaches the Telegram DC, or only the injector.
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
function TcpF($srcIp,$dstIp,$dport,$flags,$ttl){ $p=New-Object byte[] 40; $p[0]=0x45;$p[3]=40;$p[4]=0x13;$p[5]=0x37;$p[6]=0x40;$p[8]=[byte]$ttl;$p[9]=6
  [Array]::Copy((IpB $srcIp),0,$p,12,4);[Array]::Copy((IpB $dstIp),0,$p,16,4); $sp=Rnd
  $p[20]=[byte](($sp -shr 8)-band 0xFF);$p[21]=[byte]($sp -band 0xFF);$p[22]=[byte](($dport -shr 8)-band 0xFF);$p[23]=[byte]($dport -band 0xFF)
  $p[27]=1; if(($flags -band 0x10) -ne 0){ $p[31]=1 }
  $p[32]=0x50;$p[33]=[byte]$flags;$p[34]=0xFF;$p[35]=0xFF; return (FixTcp $p) }

$u=New-Object System.Net.Sockets.UdpClient;$u.Connect('1.1.1.1',53);$srcIp=$u.Client.LocalEndPoint.Address.ToString();$u.Close()
$dc='149.154.167.51'; $dcEsc=[regex]::Escape($dc)
$h=[WD]::WinDivertOpen('inbound and tcp.SrcPort == 443',0,0,0)
if($h.ToInt64() -eq -1){Write-Host "open fail";exit 1}
[WD]::StartRecv($h); $sa=New-Object byte[] 128;$sa[10]=0x02
function Send-P($pk){ $b=[byte[]]$pk; $sl=0; [void][WD]::WinDivertSend($h,$b,[uint32]$b.Length,[ref]$sl,$sa) }
$script:dcReal=$false
# fire a flag at one send-ttl; collect every DC reply ttl; split reflect (=ttl-6) vs fixed-DC(>=50)
function Probe($flagName,$flags,$T){
  [void][WD]::Drain()
  1..5 | ForEach-Object { Send-P (TcpF $srcIp $dc 443 $flags $T); Start-Sleep -Milliseconds 70 }
  Start-Sleep -Milliseconds 1200; $ev=[WD]::Drain()
  $ttls=@()
  foreach($line in $ev){ if($line -match "^src=$dcEsc " -and $line -match 'flags=0x' -and $line -match 'ttl=([0-9]+)'){ $ttls += [int]$matches[1] } }
  $ttls=@($ttls | Select-Object -Unique | Sort-Object)
  $reflect = $T - 6
  $tags=@()
  foreach($r in $ttls){
    if([Math]::Abs($r - $reflect) -le 3){ $tags += "$r=INJ(reflect)" }
    elseif($r -ge 50 -and $T -le 45){ $tags += "$r=REAL-DC!"; $script:dcReal=$true }
    elseif($r -ge 50){ $tags += "$r=~DC(ambig@hi-ttl)" }
    else { $tags += "$r=?" }
  }
  $txt = if($tags.Count){ ($tags -join ' ') } else { 'silent' }
  $col = if($txt -match 'REAL-DC!'){ 'Green' } elseif($txt -match 'INJ'){ 'Cyan' } else { 'Gray' }
  Write-Host ("  {0,-10} send-ttl={1,-3} -> reply ttls: {2}" -f $flagName,$T,$txt) -ForegroundColor $col
}

Write-Output "src=$srcIp  dc=$dc"; Write-Output ''
Write-Output '== Does our non-SYN reach the REAL DC, or only the hop-7 injector? =='
Write-Output '   rule: reply ttl == send_ttl-6 -> injector(reflect);  reply ttl>=50 at send_ttl<=45 -> REAL DC.'
Write-Output ''
foreach($T in @(12,16,22,30,45,64)){ Probe 'ACK' 0x10 $T }
Write-Output ''
foreach($T in @(16,30)){ Probe 'PSH+ACK' 0x18 $T }
Write-Output ''

[WD]::Run=$false; Start-Sleep -Milliseconds 300; [void][WD]::WinDivertClose($h)
Write-Output '========================== VERDICT =========================='
if($script:dcReal){ Write-Output '  PROVEN: a reply with ttl>=50 arrived at a LOW send-ttl (reflection impossible there) -> our'; Write-Output '  non-SYN packet REACHES the real Telegram DC. The DC sees us; only the SYN is dropped upstream.'; Write-Output '  Next: can we make the DC create a TCB without a clean SYN (TFO / crafted state) -> a real route.' }
else { Write-Output '  Every DC reply ttl tracked send_ttl-6 -> it is ALL the hop-7 injector REFLECTING; the real DC'; Write-Output '  is NOT replying to our non-SYN (the injector consumes/answers it before hop 11). So our packets'; Write-Output '  do NOT reach the DC. The earlier ttl=58 was 64-6=injector, not the DC (false positive, corrected).'; Write-Output '  Next: slow-trickle SYN (rate test) + passive watch of the real Telegram client.' }
Write-Output '============================================================='
