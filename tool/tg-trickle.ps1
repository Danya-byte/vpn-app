# tg-trickle.ps1 - test the RATE hypothesis that explains "urezan, ne zablokirovan do kontsa".
# Every prior SYN test fired in BURSTS (81 SYNs @18ms; batches of 3). A token-bucket SYN-dropper
# drops a burst but may let a RARE, well-SPACED SYN through -- which is exactly "throttled, not
# fully blocked": the client slowly retries and occasionally a SYN slips to the DC. So: send ONE
# SYN every ~7s, rotating across 4 real DCs, for ~90s, and watch for a real SYN-ACK. A SYN is
# dropped at hop 3 (never reaches the hop-7 injector), so ANY non-silent reply here is the REAL
# DC: SYN-ACK ttl>=40 = the handshake's first packet got through -> server-less crack; we pin it.
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
function SynPkt($srcIp,$dstIp,$dport){ $opt=@(0x02,0x04,0x05,0xB4,0x01,0x03,0x03,0x08,0x01,0x01,0x04,0x02); $p=New-Object byte[] 52
  $p[0]=0x45;$p[3]=52;$p[4]=0x13;$p[5]=0x37;$p[6]=0x40;$p[8]=64;$p[9]=6
  [Array]::Copy((IpB $srcIp),0,$p,12,4);[Array]::Copy((IpB $dstIp),0,$p,16,4); $sp=Rnd
  $p[20]=[byte](($sp -shr 8)-band 0xFF);$p[21]=[byte]($sp -band 0xFF);$p[22]=[byte](($dport -shr 8)-band 0xFF);$p[23]=[byte]($dport -band 0xFF)
  $p[27]=1;$p[32]=0x80;$p[33]=0x02;$p[34]=0xFF;$p[35]=0xFF; for($k=0;$k -lt $opt.Length;$k++){ $p[40+$k]=[byte]$opt[$k] }; return (FixTcp $p) }

$u=New-Object System.Net.Sockets.UdpClient;$u.Connect('1.1.1.1',53);$srcIp=$u.Client.LocalEndPoint.Address.ToString();$u.Close()
$h=[WD]::WinDivertOpen('inbound and tcp.SrcPort == 443',0,0,0)
if($h.ToInt64() -eq -1){Write-Host "open fail";exit 1}
[WD]::StartRecv($h); $sa=New-Object byte[] 128;$sa[10]=0x02
function Send-P($pk){ $b=[byte[]]$pk; $sl=0; [void][WD]::WinDivertSend($h,$b,[uint32]$b.Length,[ref]$sl,$sa) }
$dcs=@('149.154.167.51','149.154.175.50','149.154.171.5','91.108.56.130')

Write-Output "src=$srcIp"
Write-Output '== SLOW-TRICKLE SYN (1 per ~7s, rotating 4 DCs, ~90s). A rate-limited dropper may pass a spaced SYN. =='
Write-Output '   Open Telegram Desktop too (no VPN) -- its own retries add to the trickle and we sniff every :443 reply.'
Write-Output ''
$gaps=@(3,5,7,9,12,7,5,9,15,7,9,12,7,5)   # mixed spacing to probe different refill rates
$win=$false
for($i=0;$i -lt $gaps.Count;$i++){
  $ip=$dcs[$i % $dcs.Count]
  [void][WD]::Drain(); Send-P (SynPkt $srcIp $ip 443); Start-Sleep -Milliseconds 1800; $ev=[WD]::Drain()
  $esc=[regex]::Escape($ip)
  $sa1=@($ev|Where-Object{ $_ -match "^src=$esc " -and $_ -match 'flags=0x12' -and $_ -match 'ttl=([0-9]+)' -and [int]([regex]::Match($_,'ttl=([0-9]+)').Groups[1].Value) -ge 40 })
  $rst=@($ev|Where-Object{ $_ -match "^src=$esc " -and ($_ -match 'flags=0x04' -or $_ -match 'flags=0x14') -and [int]([regex]::Match($_,'ttl=([0-9]+)').Groups[1].Value) -ge 40 })
  if($sa1){ Write-Host ("  [{0,2}] SYN->{1,-16}:443 gap={2,2}s -> SYN-ACK! {3}" -f $i,$ip,$gaps[$i],$sa1[0]) -ForegroundColor Green; $win=$true }
  elseif($rst){ Write-Host ("  [{0,2}] SYN->{1,-16}:443 gap={2,2}s -> real RST (IP up) {3}" -f $i,$ip,$gaps[$i],$rst[0]) -ForegroundColor Cyan; $win=$true }
  else { Write-Host ("  [{0,2}] SYN->{1,-16}:443 gap={2,2}s -> silent" -f $i,$ip,$gaps[$i]) -ForegroundColor Gray }
  Start-Sleep -Seconds $gaps[$i]
}
Write-Output ''
[WD]::Run=$false; Start-Sleep -Milliseconds 300; [void][WD]::WinDivertClose($h)
Write-Output '========================== VERDICT =========================='
if($win){ Write-Output '  HIT: a spaced SYN got a REAL reply from a DC -> the drop is RATE-BASED, not absolute. That is'; Write-Output '  the "urezan" mechanism. Next: find the exact pass-rate and pace our SYNs under it = server-less route.' }
else { Write-Output '  Every spaced SYN still silent -> the SYN-drop is NOT a simple rate bucket at these intervals.'; Write-Output '  Next: passive watch of the real Telegram Desktop (run it, no VPN) to capture which IP/port/transport'; Write-Output '  IT actually reaches -- if Telegram half-works for you, the working client knows a path we can copy.' }
Write-Output '============================================================='
