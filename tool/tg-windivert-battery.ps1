# tg-windivert-battery.ps1 - exhaustive WinDivert characterization + evasion battery.
# We have root + the network in hand. This crafts raw packets ourselves and SNIFFS every
# inbound reply (TCP flags, ICMP type/code + the embedded original dst, UDP) to (a) prove
# the crafter works, (b) map WHERE/HOW the box drops, (c) try many evasion combos.
#
# RUN AS ADMINISTRATOR, app FULLY CLOSED. Self-relaunches into 64-bit PowerShell.

$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host 'ERROR: run AS ADMINISTRATOR.' -ForegroundColor Red; exit 1
}
$cw = Join-Path (Split-Path $PSScriptRoot -Parent) 'core\windows'
if (-not (Test-Path (Join-Path $cw 'WinDivert.dll'))) { Write-Host "WinDivert.dll not in $cw" -ForegroundColor Red; exit 1 }
[Environment]::CurrentDirectory = $cw; $env:PATH = "$cw;$env:PATH"
$db = [System.IO.File]::ReadAllBytes((Join-Path $cw 'WinDivert.dll'))
$dll64 = ([BitConverter]::ToUInt16($db, [BitConverter]::ToInt32($db, 0x3C) + 4) -eq 0x8664)
if ($dll64 -ne [Environment]::Is64BitProcess -and -not $env:TG_WD_RELAUNCH) {
  $env:TG_WD_RELAUNCH = '1'
  $alt = if ($dll64) { Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe' } else { Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe' }
  Write-Host "relaunching matching-bitness PowerShell..." -ForegroundColor Yellow
  if (Test-Path $alt) { & $alt -ExecutionPolicy Bypass -File $PSCommandPath; exit $LASTEXITCODE }
  Write-Host "no matching powershell.exe found." -ForegroundColor Red; exit 1
}

$cs = @'
using System; using System.Runtime.InteropServices; using System.Threading; using System.Collections.Generic;
public static class WD {
  [DllImport("WinDivert.dll", CharSet=CharSet.Ansi, SetLastError=true)] public static extern IntPtr WinDivertOpen(string f, int l, short p, ulong fl);
  [DllImport("WinDivert.dll", SetLastError=true)] public static extern bool WinDivertSend(IntPtr h, byte[] p, uint n, out uint s, byte[] a);
  [DllImport("WinDivert.dll", SetLastError=true)] public static extern bool WinDivertRecv(IntPtr h, byte[] p, uint n, out uint r, byte[] a);
  [DllImport("WinDivert.dll", SetLastError=true)] public static extern bool WinDivertClose(IntPtr h);
  [DllImport("WinDivert.dll", SetLastError=true)] public static extern bool WinDivertHelperCalcChecksums(byte[] p, uint n, byte[] a, ulong fl);
  public static List<string> Log = new List<string>(); public static volatile bool Run = true;
  public static void RecvLoop(IntPtr h){
    byte[] pkt=new byte[2048]; byte[] addr=new byte[128]; uint rl;
    while(Run){ if(!WinDivertRecv(h,pkt,(uint)pkt.Length,out rl,addr)) break; if(rl<20) continue;
      int ihl=(pkt[0]&0x0F)*4; int proto=pkt[9]; string src=pkt[12]+"."+pkt[13]+"."+pkt[14]+"."+pkt[15];
      string ev="src="+src+" proto="+proto;
      if(proto==1 && rl>=ihl+2){ int t=pkt[ihl]; int c=pkt[ihl+1]; ev+=" icmp="+t+"/"+c;
        if((t==3||t==11)&&rl>=ihl+8+20){ int o=ihl+8; ev+=" origdst="+pkt[o+16]+"."+pkt[o+17]+"."+pkt[o+18]+"."+pkt[o+19]; } }
      else if(proto==6 && rl>=ihl+14){ ev+=" tcpflags=0x"+pkt[ihl+13].ToString("X2"); }
      lock(Log){ Log.Add(ev); } }
  }
  public static void StartRecv(IntPtr h){ var t=new Thread(()=>RecvLoop(h)); t.IsBackground=true; t.Start(); }
  public static string[] Drain(){ lock(Log){ var a=Log.ToArray(); Log.Clear(); return a; } }
}
'@
Add-Type -TypeDefinition $cs

function IpBytes($ip) { return ([System.Net.IPAddress]::Parse($ip)).GetAddressBytes() }
function Build-Tcp($srcIp,$dstIp,$sp,$dp,[byte]$flags,[byte[]]$ipOpts,[byte[]]$tcpOpts,[int]$ttl,[int]$ipFlagByte) {
  if(-not $ipOpts){$ipOpts=@()}; if(-not $tcpOpts){$tcpOpts=@()}
  $ipOpts=@($ipOpts); while($ipOpts.Count%4){$ipOpts+=[byte]0}
  $tcpOpts=@($tcpOpts); while($tcpOpts.Count%4){$tcpOpts+=[byte]1}
  $ihl=5+[int]($ipOpts.Count/4); $iph=$ihl*4
  $tdw=5+[int]($tcpOpts.Count/4); $th=$tdw*4
  $tot=$iph+$th; $p=New-Object byte[] $tot
  $p[0]=[byte](0x40 -bor $ihl); $p[1]=0; $p[2]=[byte](($tot -shr 8)-band 0xFF); $p[3]=[byte]($tot -band 0xFF)
  $p[4]=0x13;$p[5]=0x37; $p[6]=[byte]$ipFlagByte; $p[7]=0; $p[8]=[byte]$ttl; $p[9]=6
  [Array]::Copy((IpBytes $srcIp),0,$p,12,4); [Array]::Copy((IpBytes $dstIp),0,$p,16,4)
  if($ipOpts.Count){[Array]::Copy($ipOpts,0,$p,20,$ipOpts.Count)}
  $t=$iph
  $p[$t]=[byte](($sp -shr 8)-band 0xFF);$p[$t+1]=[byte]($sp -band 0xFF);$p[$t+2]=[byte](($dp -shr 8)-band 0xFF);$p[$t+3]=[byte]($dp -band 0xFF)
  $p[$t+7]=1; $p[$t+12]=[byte]($tdw -shl 4); $p[$t+13]=$flags; $p[$t+14]=0xFF;$p[$t+15]=0xFF
  if($tcpOpts.Count){[Array]::Copy($tcpOpts,0,$p,$t+20,$tcpOpts.Count)}
  return $p
}
function Build-Udp($srcIp,$dstIp,$sp,$dp,[int]$ttl){
  $tot=20+8+4; $p=New-Object byte[] $tot
  $p[0]=0x45;$p[2]=[byte](($tot -shr 8)-band 0xFF);$p[3]=[byte]($tot -band 0xFF);$p[6]=0x40;$p[8]=[byte]$ttl;$p[9]=17
  [Array]::Copy((IpBytes $srcIp),0,$p,12,4);[Array]::Copy((IpBytes $dstIp),0,$p,16,4)
  $p[20]=[byte](($sp -shr 8)-band 0xFF);$p[21]=[byte]($sp -band 0xFF);$p[22]=[byte](($dp -shr 8)-band 0xFF);$p[23]=[byte]($dp -band 0xFF)
  $p[24]=0;$p[25]=12  # udp len = 8+4
  return $p
}
function Build-Raw($srcIp,$dstIp,[int]$proto,[int]$ttl){
  $tot=20+8; $p=New-Object byte[] $tot
  $p[0]=0x45;$p[2]=[byte](($tot -shr 8)-band 0xFF);$p[3]=[byte]($tot -band 0xFF);$p[6]=0x40;$p[8]=[byte]$ttl;$p[9]=[byte]$proto
  [Array]::Copy((IpBytes $srcIp),0,$p,12,4);[Array]::Copy((IpBytes $dstIp),0,$p,16,4)
  return $p
}
function OptLsrr($ips){ $b=@([byte]0x83,[byte](3+4*$ips.Count),[byte]4); foreach($ip in $ips){$b+=(IpBytes $ip)}; return [byte[]]$b }
function Cksum16($p,$start,$end,$seed){
  $s=$seed; for($i=$start;$i -lt $end;$i+=2){ $hi=$p[$i]; $lo=0; if($i+1 -lt $end){$lo=$p[$i+1]}; $s+=(([int]$hi -shl 8) -bor [int]$lo) }
  while($s -shr 16){ $s=($s -band 0xFFFF)+($s -shr 16) }; return ((-bnot $s) -band 0xFFFF)
}
function Fix-Checksums([byte[]]$p){
  $ihl=($p[0] -band 0x0F)*4
  $p[10]=0;$p[11]=0
  $ic=Cksum16 $p 0 $ihl 0; $p[10]=[byte](($ic -shr 8)-band 0xFF);$p[11]=[byte]($ic -band 0xFF)
  $proto=$p[9]; $t=$ihl; $segLen=$p.Length-$ihl
  if($proto -eq 6 -or $proto -eq 17){
    # pseudo-header sum: src+dst+proto+segLen
    $ph=0; $ph+=(([int]$p[12]-shl 8)-bor $p[13]);$ph+=(([int]$p[14]-shl 8)-bor $p[15])
    $ph+=(([int]$p[16]-shl 8)-bor $p[17]);$ph+=(([int]$p[18]-shl 8)-bor $p[19]); $ph+=$proto; $ph+=$segLen
    $coff=if($proto -eq 6){$t+16}else{$t+6}
    $p[$coff]=0;$p[$coff+1]=0
    $cs=Cksum16 $p $t $p.Length $ph
    if($proto -eq 17 -and $cs -eq 0){$cs=0xFFFF}
    $p[$coff]=[byte](($cs -shr 8)-band 0xFF);$p[$coff+1]=[byte]($cs -band 0xFF)
  }
  return $p
}

$u=New-Object System.Net.Sockets.UdpClient; $u.Connect('1.1.1.1',53); $srcIp=$u.Client.LocalEndPoint.Address.ToString(); $u.Close()
$dc='149.154.167.51'
Write-Output "src=$srcIp  dc=$dc  (TG ranges: 149.154/91.108/95.161)"

$filter='inbound and (icmp or ((tcp or udp) and (ip.SrcAddr == 1.1.1.1 or (ip.SrcAddr >= 149.154.160.0 and ip.SrcAddr <= 149.154.175.255) or (ip.SrcAddr >= 91.108.4.0 and ip.SrcAddr <= 91.108.59.255) or (ip.SrcAddr >= 95.161.64.0 and ip.SrcAddr <= 95.161.79.255))))'
$h=[WD]::WinDivertOpen($filter,0,0,0)
if($h.ToInt64() -eq -1){Write-Host "WinDivertOpen failed (err $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))" -ForegroundColor Red; exit 1}
[WD]::StartRecv($h)
$sa=New-Object byte[] 128; $sa[10]=0x02
function Send-Pkt($pkt){ $pkt=Fix-Checksums $pkt; $sl=0; return [WD]::WinDivertSend($h,$pkt,[uint32]$pkt.Length,[ref]$sl,$sa) }
function Rnd(){ return Get-Random -Minimum 20000 -Maximum 60000 }
function SynAck($ev,$fromIp){ return @($ev | Where-Object { $_ -like "src=$fromIp *" -and $_ -match 'tcpflags=0x12' }).Count -gt 0 }
function AnyFrom($ev,$fromIp){ return @($ev | Where-Object { $_ -like "src=$fromIp *" }).Count -gt 0 }

Write-Output ''
Write-Output '== VALIDATION =='
[void][WD]::Drain(); for($i=0;$i -lt 3;$i++){[void](Send-Pkt (Build-Tcp $srcIp '1.1.1.1' (Rnd) 443 0x02 $null $null 64 0)); Start-Sleep -Milliseconds 150}
Start-Sleep -Milliseconds 1500; $ev=[WD]::Drain()
$ctrl = SynAck $ev '1.1.1.1'
Write-Host ("  0 CONTROL SYN->1.1.1.1 : {0}" -f $(if($ctrl){'SYN-ACK back -> CRAFTER WORKS'}else{'no reply -> CRAFTER BROKEN (rest invalid)'})) -ForegroundColor $(if($ctrl){'Green'}else{'Red'})

Write-Output ''
Write-Output '== CHARACTERIZATION =='
# TTL sweep: where does OUR SYN to the DC die? (icmp time-exceeded src = the hop)
Write-Output '  TTL sweep SYN->DC (which hop kills it; compare ICMP-echo reached hop 11):'
for($ttl=1;$ttl -le 12;$ttl++){
  [void][WD]::Drain(); [void](Send-Pkt (Build-Tcp $srcIp $dc (Rnd) 443 0x02 $null $null $ttl 0)); Start-Sleep -Milliseconds 700; $ev=[WD]::Drain()
  $exc = @($ev | Where-Object { $_ -match 'icmp=11/' -and $_ -match "origdst=$dc" })
  $sa2 = SynAck $ev $dc
  $hop = if($exc.Count){ ($exc[0] -split ' ')[0].Replace('src=','') } elseif($sa2){ 'SYN-ACK!!' } else { '(silent)' }
  Write-Host ("    ttl={0,-2} -> {1}" -f $ttl,$hop)
}
# is it SYN-specific or any TCP? send a bare ACK to the DC
[void][WD]::Drain(); for($i=0;$i -lt 3;$i++){[void](Send-Pkt (Build-Tcp $srcIp $dc (Rnd) 443 0x10 $null $null 64 0)); Start-Sleep -Milliseconds 150}
Start-Sleep -Milliseconds 1200; $ev=[WD]::Drain()
Write-Host ("  ACK(non-SYN)->DC : {0}" -f $(if(AnyFrom $ev $dc){'reply (TCP not fully blocked!)'}else{'silent (all TCP dropped)'}))
# UDP to the DC
[void][WD]::Drain(); foreach($p in @(443,500,3478)){[void](Send-Pkt (Build-Udp $srcIp $dc (Rnd) $p 64))}; Start-Sleep -Milliseconds 1500; $ev=[WD]::Drain()
$udp = @($ev | Where-Object { $_ -like "src=$dc *" -or ($_ -match 'icmp=3/' -and $_ -match "origdst=$dc") })
Write-Host ("  UDP->DC : {0}" -f $(if($udp.Count){'REACHED (proto 17 passes!) -> '+($udp[0])}else{'silent (UDP dropped too, or unreach suppressed)'})) -ForegroundColor $(if($udp.Count){'Green'}else{'Gray'})
# GRE (proto 47) to the DC
[void][WD]::Drain(); [void](Send-Pkt (Build-Raw $srcIp $dc 47 64)); Start-Sleep -Milliseconds 1200; $ev=[WD]::Drain()
Write-Host ("  GRE(47)->DC : {0}" -f $(if(AnyFrom $ev $dc -or (@($ev|Where-Object{$_ -match "origdst=$dc"}).Count)){'reply (non-TCP/UDP passes!)'}else{'silent'}))

Write-Output ''
Write-Output '== EVASION COMBOS (any SYN-ACK from a TG IP = CRACKED) =='
$tcpOptsFull = [byte[]]@(0x02,0x04,0x05,0xB4, 0x04,0x02, 0x08,0x0A,0x11,0x22,0x33,0x44,0,0,0,0, 0x01, 0x03,0x03,0x07)
$combos = @(
  @{ n='E1 baseline SYN';        f={ Build-Tcp $srcIp $dc (Rnd) 443 0x02 $null $null 64 0 } },
  @{ n='E2 SYN+full TCP opts';   f={ Build-Tcp $srcIp $dc (Rnd) 443 0x02 $null $tcpOptsFull 64 0 } },
  @{ n='E3 SYN+IP LSRR';         f={ Build-Tcp $srcIp $dc (Rnd) 443 0x02 (OptLsrr @('1.1.1.1')) $null 64 0 } },
  @{ n='E4 SYN+evil-bit(IP)';    f={ Build-Tcp $srcIp $dc (Rnd) 443 0x02 $null $null 64 0x80 } },
  @{ n='E5 SYN+DF+resv flags';   f={ Build-Tcp $srcIp $dc (Rnd) 443 0x02 $null $null 64 0x60 } },
  @{ n='E6 SYN dport=80';        f={ Build-Tcp $srcIp $dc (Rnd) 80  0x02 $null $null 64 0 } },
  @{ n='E7 SYN dport=12345';     f={ Build-Tcp $srcIp $dc (Rnd) 12345 0x02 $null $null 64 0 } }
)
$cracked=''
foreach($c in $combos){
  [void][WD]::Drain(); for($i=0;$i -lt 3;$i++){[void](Send-Pkt (& $c.f)); Start-Sleep -Milliseconds 120}
  Start-Sleep -Milliseconds 1300; $ev=[WD]::Drain()
  $ok = @($ev | Where-Object { $_ -match 'tcpflags=0x12' -and $_ -notlike 'src=1.1.1.1 *' }).Count -gt 0
  if($ok){ $s=@($ev|Where-Object{$_ -match 'tcpflags=0x12'})[0]; $cracked="$($c.n): $s"; Write-Host ("  {0,-22} SYN-ACK!  {1}" -f $c.n,$s) -ForegroundColor Green }
  else { Write-Host ("  {0,-22} silent" -f $c.n) -ForegroundColor Gray }
}
# E8 burst: 250 SYNs fast, then listen (sampling / fail-open)
Write-Output '  E8 burst 250x SYN->DC (sampling/fail-open)...'
[void][WD]::Drain(); for($i=0;$i -lt 250;$i++){[void](Send-Pkt (Build-Tcp $srcIp $dc (Rnd) 443 0x02 $null $null 64 0))}
Start-Sleep -Milliseconds 2500; $ev=[WD]::Drain()
$burst=@($ev | Where-Object { $_ -match 'tcpflags=0x12' -and $_ -notlike 'src=1.1.1.1 *' })
if($burst.Count){ $cracked="E8 burst: $($burst[0])"; Write-Host ("    BURST got SYN-ACK! {0}" -f $burst[0]) -ForegroundColor Green }
else { Write-Host '    burst: silent' -ForegroundColor Gray }

[WD]::Run=$false; Start-Sleep -Milliseconds 300; [void][WD]::WinDivertClose($h)
Write-Output ''
Write-Output '========================== VERDICT =========================='
if(-not $ctrl){ Write-Output 'CONTROL FAILED -> the crafter is broken; all results above are INVALID. I fix the injector.' }
elseif($cracked){ Write-Output "CRACKED: $cracked  -> direct server-less route exists; I build a WinDivert transport around it." }
else {
  Write-Output 'Crafter VALIDATED (control replied) but every TG probe is silent: SYN, all options/flags,'
  Write-Output 'all ports, the 250-burst -- nothing returns. The TTL sweep shows where the SYN dies. If TG'
  Write-Output 'TCP dies before hop 11 while ICMP-echo reached hop 11 = a TCP-only middlebox; if UDP/GRE'
  Write-Output 'also silent = proto-agnostic dst-IP ACL. Send the full output -- the TTL/UDP rows decide'
  Write-Output 'the last remaining angles (UDP transport, or middlebox-localized TTL trick).'
}
Write-Output '============================================================='
