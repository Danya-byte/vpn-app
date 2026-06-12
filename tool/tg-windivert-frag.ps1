# tg-windivert-frag.ps1 - IP-fragment + OVERLAP evasion of the SYN-dropping middlebox.
#
# Findings so far (validated crafter): the box reads TCP flags (drops SYN, RST-injects ACK
# at ttl=58 ~hop6). Since it INSPECTS the flag byte, we hide/contradict it with IP frags:
#  - plain frag: TCP flag byte lands in fragment 2; the box sees frag1 (no flags) -> can't
#    classify as SYN -> may pass; Telegram reassembles -> SYN.
#  - OVERLAP frag: frag1 carries flags=ACK, frag2 OVERLAPS with flags=SYN. If the box does
#    first-wins reassembly it sees ACK (forwards+fake-RST, does NOT drop); if Telegram does
#    last-wins it sees SYN -> SYN-ACK. (And the reverse, for the opposite policies.)
# CONTROL: a fragmented SYN to 1.1.1.1 must still get a SYN-ACK -> proves frags survive our
# CGNAT (if winws-ipfrag "failed" only because the CGNAT dropped frags, this reveals it).
#
# WIN = any SYN-ACK (0x12) from a TG IP, OR a RST from a TG IP with ttl ~53 (=11 hops, a
# REAL Telegram RST -> our packet REACHED Telegram). A ttl~58 RST is the middlebox (no win).
#
# RUN AS ADMINISTRATOR, app CLOSED. Self-relaunches to 64-bit.

$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Write-Host 'run AS ADMIN' -ForegroundColor Red; exit 1 }
$cw = Join-Path (Split-Path $PSScriptRoot -Parent) 'core\windows'
[Environment]::CurrentDirectory = $cw; $env:PATH = "$cw;$env:PATH"
$db = [System.IO.File]::ReadAllBytes((Join-Path $cw 'WinDivert.dll'))
$dll64 = ([BitConverter]::ToUInt16($db, [BitConverter]::ToInt32($db, 0x3C) + 4) -eq 0x8664)
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
  public static List<string> Log = new List<string>(); public static volatile bool Run = true;
  public static void RecvLoop(IntPtr h){ byte[] pkt=new byte[2048]; byte[] addr=new byte[128]; uint rl;
    while(Run){ if(!WinDivertRecv(h,pkt,(uint)pkt.Length,out rl,addr)) break; if(rl<20) continue;
      int ihl=(pkt[0]&0x0F)*4; int proto=pkt[9]; string src=pkt[12]+"."+pkt[13]+"."+pkt[14]+"."+pkt[15];
      string ev="src="+src+" ttl="+pkt[8]; if(proto==6 && rl>=ihl+14) ev+=" flags=0x"+pkt[ihl+13].ToString("X2"); else ev+=" proto="+proto;
      lock(Log){ Log.Add(ev); } } }
  public static void StartRecv(IntPtr h){ var t=new Thread(()=>RecvLoop(h)); t.IsBackground=true; t.Start(); }
  public static string[] Drain(){ lock(Log){ var a=Log.ToArray(); Log.Clear(); return a; } }
}
'@
Add-Type -TypeDefinition $cs
function IpB($ip){ return ([System.Net.IPAddress]::Parse($ip)).GetAddressBytes() }
function Ck($p,$s,$e,$seed){ $sum=$seed; for($i=$s;$i -lt $e;$i+=2){ $lo=0; if($i+1 -lt $e){$lo=$p[$i+1]}; $sum+=(([int]$p[$i]-shl 8)-bor [int]$lo) }; while($sum -shr 16){$sum=($sum -band 0xFFFF)+($sum -shr 16)}; return ((-bnot $sum)-band 0xFFFF) }
# full 20-byte TCP segment WITH correct TCP checksum (pseudo-header from src/dst)
function Tcp20($srcIp,$dstIp,$sp,$dp,[byte]$flags){
  $t=New-Object byte[] 20
  $t[0]=[byte](($sp -shr 8)-band 0xFF);$t[1]=[byte]($sp -band 0xFF);$t[2]=[byte](($dp -shr 8)-band 0xFF);$t[3]=[byte]($dp -band 0xFF)
  $t[7]=1;$t[12]=0x50;$t[13]=$flags;$t[14]=0xFF;$t[15]=0xFF
  $ph=0;$sb=IpB $srcIp;$dbb=IpB $dstIp
  $ph+=(([int]$sb[0]-shl 8)-bor $sb[1]);$ph+=(([int]$sb[2]-shl 8)-bor $sb[3]);$ph+=(([int]$dbb[0]-shl 8)-bor $dbb[1]);$ph+=(([int]$dbb[2]-shl 8)-bor $dbb[3]);$ph+=6;$ph+=20
  $c=Ck $t 0 20 $ph; $t[16]=[byte](($c -shr 8)-band 0xFF);$t[17]=[byte]($c -band 0xFF); return $t
}
# one IP fragment: ihl=20, proto=6, given payload slice + fragOffset(units of 8) + MF
function Frag($srcIp,$dstIp,$id,[byte[]]$pl,$offU,$mf){
  $tot=20+$pl.Count; $p=New-Object byte[] $tot
  $p[0]=0x45;$p[2]=[byte](($tot -shr 8)-band 0xFF);$p[3]=[byte]($tot -band 0xFF)
  $p[4]=[byte](($id -shr 8)-band 0xFF);$p[5]=[byte]($id -band 0xFF)
  $b6=[int](($offU -shr 8)-band 0x1F); if($mf){$b6=$b6 -bor 0x20}; $p[6]=[byte]$b6; $p[7]=[byte]($offU -band 0xFF)
  $p[8]=64;$p[9]=6; [Array]::Copy((IpB $srcIp),0,$p,12,4);[Array]::Copy((IpB $dstIp),0,$p,16,4)
  [Array]::Copy($pl,0,$p,20,$pl.Count)
  $ic=Ck $p 0 20 0; $p[10]=[byte](($ic -shr 8)-band 0xFF);$p[11]=[byte]($ic -band 0xFF); return $p
}
function Slice([byte[]]$a,$start,$len){ $r=New-Object byte[] $len; [Array]::Copy($a,$start,$r,0,$len); return ,$r }

$u=New-Object System.Net.Sockets.UdpClient;$u.Connect('1.1.1.1',53);$srcIp=$u.Client.LocalEndPoint.Address.ToString();$u.Close()
$dc='149.154.167.51'
$filter='inbound and tcp.SrcPort == 443 and (ip.SrcAddr == 1.1.1.1 or (ip.SrcAddr >= 149.154.160.0 and ip.SrcAddr <= 149.154.175.255) or (ip.SrcAddr >= 91.108.4.0 and ip.SrcAddr <= 91.108.59.255) or (ip.SrcAddr >= 95.161.64.0 and ip.SrcAddr <= 95.161.79.255))'
$h=[WD]::WinDivertOpen($filter,0,0,0); if($h.ToInt64() -eq -1){Write-Host "open fail";exit 1}
[WD]::StartRecv($h); $sa=New-Object byte[] 128;$sa[10]=0x02
function SendRaw($pk){ $sl=0; [void][WD]::WinDivertSend($h,$pk,[uint32]$pk.Length,[ref]$sl,$sa) }
function Rnd(){ Get-Random -Minimum 20000 -Maximum 60000 }
function FromDc($ev,$ip){ return @($ev | Where-Object { $_ -like "src=$ip *" }) }

# probe = list of fragments to send (in order); repeat 3x
function Probe($name,$ip,$mkFrags){
  [void][WD]::Drain()
  for($r=0;$r -lt 3;$r++){ $id=Rnd; foreach($f in (& $mkFrags $id)){ SendRaw $f }; Start-Sleep -Milliseconds 200 }
  Start-Sleep -Milliseconds 1500; $ev=[WD]::Drain(); $rep=FromDc $ev $ip
  if($rep){ $r0=$rep[0]; $sa2=$r0 -match 'flags=0x12'
    $col=if($sa2){'Green'}elseif($r0 -match 'ttl=5[0-4]'){'Green'}else{'Yellow'}
    Write-Host ("  {0,-26} REPLY: {1}{2}" -f $name,$r0,$(if($sa2){'  <<< SYN-ACK!'}elseif($r0 -match 'ttl=5[0-4]'){'  <<< REAL TG RST (reached!)'}else{'  (injected RST)'})) -ForegroundColor $col
    return $r0 }
  else { Write-Host ("  {0,-26} silent" -f $name) -ForegroundColor Gray; return $null }
}

$sp=Rnd
Write-Output "src=$srcIp dc=$dc"; Write-Output ''
# CONTROL: plain 2-frag SYN to 1.1.1.1 (must reassemble -> SYN-ACK)
$rC = Probe 'CONTROL frag-SYN 1.1.1.1' '1.1.1.1' { param($id) $s=Tcp20 $srcIp '1.1.1.1' $sp 443 0x02; @( (Frag $srcIp '1.1.1.1' $id (Slice $s 0 8) 0 $true), (Frag $srcIp '1.1.1.1' $id (Slice $s 8 12) 1 $false) ) }
Write-Output ''
Write-Output '== fragmented / overlapping SYN to the Telegram DC =='
# V1 plain frag, flags in frag2
[void](Probe 'V1 plain frag (flags@frag2)' $dc { param($id) $s=Tcp20 $srcIp $dc $sp 443 0x02; @( (Frag $srcIp $dc $id (Slice $s 0 8) 0 $true), (Frag $srcIp $dc $id (Slice $s 8 12) 1 $false) ) })
# V1r reversed order
[void](Probe 'V1r plain frag reversed' $dc { param($id) $s=Tcp20 $srcIp $dc $sp 443 0x02; @( (Frag $srcIp $dc $id (Slice $s 8 12) 1 $false), (Frag $srcIp $dc $id (Slice $s 0 8) 0 $true) ) })
# V2 overlap: frag1=ACK[0:16], frag2=SYN[8:20] (box first-wins=ACK -> forward; TG last-wins=SYN)
[void](Probe 'V2 overlap ACK/ then SYN' $dc { param($id) $A=Tcp20 $srcIp $dc $sp 443 0x10; $S=Tcp20 $srcIp $dc $sp 443 0x02; @( (Frag $srcIp $dc $id (Slice $A 0 16) 0 $true), (Frag $srcIp $dc $id (Slice $S 8 12) 1 $false) ) })
# V3 overlap reversed: frag1=SYN[0:16], frag2=ACK[8:20] (box last-wins=ACK; TG first-wins=SYN)
[void](Probe 'V3 overlap SYN/ then ACK' $dc { param($id) $S=Tcp20 $srcIp $dc $sp 443 0x02; $A=Tcp20 $srcIp $dc $sp 443 0x10; @( (Frag $srcIp $dc $id (Slice $S 0 16) 0 $true), (Frag $srcIp $dc $id (Slice $A 8 12) 1 $false) ) })
# V4 overlap, frag2 sent FIRST (order-sensitive reassemblers)
[void](Probe 'V4 overlap, frag2 first' $dc { param($id) $A=Tcp20 $srcIp $dc $sp 443 0x10; $S=Tcp20 $srcIp $dc $sp 443 0x02; @( (Frag $srcIp $dc $id (Slice $S 8 12) 1 $false), (Frag $srcIp $dc $id (Slice $A 0 16) 0 $true) ) })
# V5 tiny 3-frag: isolate the flags byte region in the middle fragment
[void](Probe 'V5 3-frag isolate flags' $dc { param($id) $s=Tcp20 $srcIp $dc $sp 443 0x02; @( (Frag $srcIp $dc $id (Slice $s 0 8) 0 $true), (Frag $srcIp $dc $id (Slice $s 8 8) 1 $true), (Frag $srcIp $dc $id (Slice $s 16 4) 2 $false) ) })

[WD]::Run=$false; Start-Sleep -Milliseconds 300; [void][WD]::WinDivertClose($h)
Write-Output ''
Write-Output '========================== VERDICT =========================='
if(-not $rC){ Write-Output 'CONTROL frag-SYN to 1.1.1.1 SILENT -> our CGNAT/path drops fragments, so the TG frag'; Write-Output 'results are inconclusive (this is likely why winws ipfrag "failed"). Next: PMTU/no-frag tricks.' }
else { Write-Output 'CONTROL ok (frags survive + 1.1.1.1 reassembles). So the TG rows are REAL:'; Write-Output 'any green SYN-ACK / real-TG-RST = a fragmented/overlap SYN reached Telegram -> we build that'; Write-Output 'exact fragmentation as a WinDivert transport. All silent/injected = the box reassembles+drops.' }
Write-Output '============================================================='
