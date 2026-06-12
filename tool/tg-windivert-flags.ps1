# tg-windivert-flags.ps1 - exploit the "ACK passes, SYN dropped" finding.
#
# The battery proved: a bare ACK to a Telegram DC gets a reply, but every pure SYN (0x02)
# is silently dropped just after the CGNAT. So the middlebox keys on PURE-SYN (connection
# init). Linux (Telegram) accepts SYN+ECN flags (ECE/CWR) and other non-pure-SYN as a
# valid open; a strict 0x02 matcher would pass them. If any SYN-variant gets a reply FROM
# a Telegram IP (SYN-ACK 0x12 = perfect; RST 0x04 = reached-but-refused, still evaded the
# filter), we cracked it server-less and build a WinDivert SYN-rewrite transport.
#
# Also characterizes the ACK reply (real Telegram RST vs middlebox injection) by TTL.
# RUN AS ADMINISTRATOR, app CLOSED. Self-relaunches to 64-bit.

$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Write-Host 'ERROR: run AS ADMINISTRATOR.' -ForegroundColor Red; exit 1 }
$cw = Join-Path (Split-Path $PSScriptRoot -Parent) 'core\windows'
[Environment]::CurrentDirectory = $cw; $env:PATH = "$cw;$env:PATH"
$db = [System.IO.File]::ReadAllBytes((Join-Path $cw 'WinDivert.dll'))
$dll64 = ([BitConverter]::ToUInt16($db, [BitConverter]::ToInt32($db, 0x3C) + 4) -eq 0x8664)
if ($dll64 -ne [Environment]::Is64BitProcess -and -not $env:TG_WD_RELAUNCH) {
  $env:TG_WD_RELAUNCH = '1'; $alt = if ($dll64) { Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe' } else { Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe' }
  Write-Host 'relaunching matching-bitness PowerShell...' -ForegroundColor Yellow
  if (Test-Path $alt) { & $alt -ExecutionPolicy Bypass -File $PSCommandPath; exit $LASTEXITCODE } ; exit 1
}

$cs = @'
using System; using System.Runtime.InteropServices; using System.Threading; using System.Collections.Generic;
public static class WD {
  [DllImport("WinDivert.dll", CharSet=CharSet.Ansi, SetLastError=true)] public static extern IntPtr WinDivertOpen(string f, int l, short p, ulong fl);
  [DllImport("WinDivert.dll", SetLastError=true)] public static extern bool WinDivertSend(IntPtr h, byte[] p, uint n, out uint s, byte[] a);
  [DllImport("WinDivert.dll", SetLastError=true)] public static extern bool WinDivertRecv(IntPtr h, byte[] p, uint n, out uint r, byte[] a);
  [DllImport("WinDivert.dll", SetLastError=true)] public static extern bool WinDivertClose(IntPtr h);
  public static List<string> Log = new List<string>(); public static volatile bool Run = true;
  public static void RecvLoop(IntPtr h){ byte[] pkt=new byte[2048]; byte[] addr=new byte[128]; uint rl;
    while(Run){ if(!WinDivertRecv(h,pkt,(uint)pkt.Length,out rl,addr)) break; if(rl<20) continue;
      int ihl=(pkt[0]&0x0F)*4; int proto=pkt[9]; string src=pkt[12]+"."+pkt[13]+"."+pkt[14]+"."+pkt[15];
      string ev="src="+src+" ttl="+pkt[8]+" proto="+proto;
      if(proto==6 && rl>=ihl+14) ev+=" flags=0x"+pkt[ihl+13].ToString("X2");
      else if(proto==1 && rl>=ihl+2) ev+=" icmp="+pkt[ihl]+"/"+pkt[ihl+1];
      lock(Log){ Log.Add(ev); } } }
  public static void StartRecv(IntPtr h){ var t=new Thread(()=>RecvLoop(h)); t.IsBackground=true; t.Start(); }
  public static string[] Drain(){ lock(Log){ var a=Log.ToArray(); Log.Clear(); return a; } }
}
'@
Add-Type -TypeDefinition $cs

function IpBytes($ip){ return ([System.Net.IPAddress]::Parse($ip)).GetAddressBytes() }
function Build-Tcp($srcIp,$dstIp,$sp,$dp,[byte]$flags,[int]$ttl,[byte]$b12){
  $tot=40; $p=New-Object byte[] $tot
  $p[0]=0x45;$p[2]=0;$p[3]=40;$p[4]=0x13;$p[5]=0x37;$p[6]=0x40;$p[8]=[byte]$ttl;$p[9]=6
  [Array]::Copy((IpBytes $srcIp),0,$p,12,4);[Array]::Copy((IpBytes $dstIp),0,$p,16,4)
  $p[20]=[byte](($sp -shr 8)-band 0xFF);$p[21]=[byte]($sp -band 0xFF);$p[22]=[byte](($dp -shr 8)-band 0xFF);$p[23]=[byte]($dp -band 0xFF)
  $p[27]=1; $p[32]=$b12; $p[33]=$flags; $p[34]=0xFF;$p[35]=0xFF
  return $p
}
function Cksum16($p,$s,$e,$seed){ $sum=$seed; for($i=$s;$i -lt $e;$i+=2){ $lo=0; if($i+1 -lt $e){$lo=$p[$i+1]}; $sum+=(([int]$p[$i]-shl 8)-bor [int]$lo) }; while($sum -shr 16){$sum=($sum -band 0xFFFF)+($sum -shr 16)}; return ((-bnot $sum)-band 0xFFFF) }
function Fix-Cks([byte[]]$p){ $ihl=($p[0]-band 0x0F)*4; $p[10]=0;$p[11]=0; $ic=Cksum16 $p 0 $ihl 0; $p[10]=[byte](($ic -shr 8)-band 0xFF);$p[11]=[byte]($ic -band 0xFF)
  $ph=0;$ph+=(([int]$p[12]-shl 8)-bor $p[13]);$ph+=(([int]$p[14]-shl 8)-bor $p[15]);$ph+=(([int]$p[16]-shl 8)-bor $p[17]);$ph+=(([int]$p[18]-shl 8)-bor $p[19]);$ph+=6;$ph+=($p.Length-$ihl)
  $p[$ihl+16]=0;$p[$ihl+17]=0; $tc=Cksum16 $p $ihl $p.Length $ph; $p[$ihl+16]=[byte](($tc -shr 8)-band 0xFF);$p[$ihl+17]=[byte]($tc -band 0xFF); return $p }

$u=New-Object System.Net.Sockets.UdpClient;$u.Connect('1.1.1.1',53);$srcIp=$u.Client.LocalEndPoint.Address.ToString();$u.Close()
$dc='149.154.167.51'
$filter='inbound and tcp.SrcPort == 443 and (ip.SrcAddr == 1.1.1.1 or (ip.SrcAddr >= 149.154.160.0 and ip.SrcAddr <= 149.154.175.255) or (ip.SrcAddr >= 91.108.4.0 and ip.SrcAddr <= 91.108.59.255) or (ip.SrcAddr >= 95.161.64.0 and ip.SrcAddr <= 95.161.79.255))'
$h=[WD]::WinDivertOpen($filter,0,0,0)
if($h.ToInt64() -eq -1){Write-Host "open failed $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" -ForegroundColor Red;exit 1}
[WD]::StartRecv($h)
$sa=New-Object byte[] 128;$sa[10]=0x02
function Send3($mk){ for($i=0;$i -lt 3;$i++){ $pk=Fix-Cks (& $mk); $sl=0; [void][WD]::WinDivertSend($h,$pk,[uint32]$pk.Length,[ref]$sl,$sa); Start-Sleep -Milliseconds 120 } }
function Rnd(){ Get-Random -Minimum 20000 -Maximum 60000 }
function FromDc($ev){ return @($ev | Where-Object { $_ -like "src=$dc *" }) }

Write-Output "src=$srcIp dc=$dc"
Write-Output ''
[void][WD]::Drain(); Send3 { Build-Tcp $srcIp '1.1.1.1' (Rnd) 443 0x02 64 0x50 }; Start-Sleep -Milliseconds 1200; $ev=[WD]::Drain()
$ctrl=@($ev|Where-Object{$_ -like 'src=1.1.1.1 *' -and $_ -match 'flags=0x12'}).Count -gt 0
Write-Host ("CONTROL SYN->1.1.1.1 : {0}" -f $(if($ctrl){'SYN-ACK ok'}else{'BROKEN'})) -ForegroundColor $(if($ctrl){'Green'}else{'Red'})
Write-Output ''
Write-Output '== ACK characterization (real TG RST vs middlebox injection, by TTL) =='
[void][WD]::Drain(); Send3 { Build-Tcp $srcIp '1.1.1.1' (Rnd) 443 0x10 64 0x50 }; Start-Sleep -Milliseconds 1200; $ev=[WD]::Drain()
$a1=@($ev|Where-Object{$_ -like 'src=1.1.1.1 *'}); Write-Host ("  ACK->1.1.1.1 reply: {0}" -f $(if($a1){$a1[0]}else{'none'}))
[void][WD]::Drain(); Send3 { Build-Tcp $srcIp $dc (Rnd) 443 0x10 64 0x50 }; Start-Sleep -Milliseconds 1200; $ev=[WD]::Drain()
$a2=FromDc $ev; Write-Host ("  ACK->DC      reply: {0}" -f $(if($a2){$a2[0]}else{'none'})) -ForegroundColor $(if($a2){'Yellow'}else{'Gray'})
Write-Output '  (compare TTL: a real DC RST is ~11 hops from the initial TTL; a near injection has higher TTL)'
Write-Output ''
Write-Output '== SYN flag sweep to DC (reply 0x12=SYN-ACK CRACK; 0x04=RST=reached+refused) =='
$flagV = @(
  @{ n='0x02 pure SYN';      fl=0x02; b=0x50 },
  @{ n='0x42 SYN+ECE';       fl=0x42; b=0x50 },
  @{ n='0x82 SYN+CWR';       fl=0x82; b=0x50 },
  @{ n='0xC2 SYN+ECE+CWR';   fl=0xC2; b=0x50 },
  @{ n='0x0A SYN+PSH';       fl=0x0A; b=0x50 },
  @{ n='0x22 SYN+URG';       fl=0x22; b=0x50 },
  @{ n='SYN +NS(reserved)';  fl=0x02; b=0x51 },
  @{ n='SYN +resv-bit';      fl=0x02; b=0x54 },
  @{ n='0x12 SYN+ACK';       fl=0x12; b=0x50 }
)
$crack=''
foreach($v in $flagV){
  [void][WD]::Drain(); Send3 { Build-Tcp $srcIp $dc (Rnd) 443 ([byte]$v.fl) 64 ([byte]$v.b) }; Start-Sleep -Milliseconds 1300; $ev=[WD]::Drain()
  $r=FromDc $ev
  if($r){ $f=$r[0]; $synack = $f -match 'flags=0x12'
    Write-Host ("  {0,-20} REPLY: {1}{2}" -f $v.n,$f,$(if($synack){'  <<< SYN-ACK CRACK!'}else{'  (reached, refused)'})) -ForegroundColor $(if($synack){'Green'}else{'Yellow'})
    if($synack){ $crack="$($v.n): $f" } elseif(-not $crack){ $crack="reached via $($v.n): $f" } }
  else { Write-Host ("  {0,-20} silent" -f $v.n) -ForegroundColor Gray }
}
[WD]::Run=$false; Start-Sleep -Milliseconds 300; [void][WD]::WinDivertClose($h)
Write-Output ''
Write-Output '========================== VERDICT =========================='
if(-not $ctrl){ Write-Output 'CONTROL broken -> ignore results.' }
elseif($crack -like '*SYN-ACK*' -or $crack -like '0x*'){ Write-Output "CRACK: $crack -> a SYN-variant reached Telegram and it answered. I build a WinDivert" ; Write-Output 'SYN-flag-rewrite transport (rewrite outbound pure-SYN-to-TG into this variant) -- server-less.' }
elseif($crack){ Write-Output "PARTIAL: $crack -- a SYN-variant REACHED Telegram (got a RST) = the filter was EVADED, just" ; Write-Output 'wrong tuple/state. Huge: it means the SYN-flag trick passes the box. Next I complete the handshake.' }
else { Write-Output 'All SYN-variants silent -> the box drops every SYN flavor; only non-SYN passes (and can'+"'"+'t open a' ; Write-Output 'connection alone). Then the ACK-reply was likely a middlebox injection; intermediate still needed.' }
Write-Output '============================================================='
