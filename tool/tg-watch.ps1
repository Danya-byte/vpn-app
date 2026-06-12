# tg-watch.ps1 - the one empirical step we never took: PASSIVELY watch what the real Telegram
# Desktop actually does. We fired our own SYNs and they all dropped -- but the official client
# may target IPs/CDNs/ports our sweep missed, and seeing its OUTCOMES (does ANY SYN-ACK come back
# from a Telegram IP?) is authoritative ground truth. SNIFF mode: copies packets, never injects,
# never drops -- it does NOT disturb your traffic. Run it, then OPEN Telegram Desktop (no VPN) and
# let it try to connect for ~60s. We log every connection-control packet to/from Telegram ranges.
#   OUT SYN  -> a TG IP   = the client is trying that endpoint.
#   IN  SYN-ACK <- a TG IP = THAT endpoint ANSWERED = a working path (copy it!).
#   IN  RST / no reply     = blocked, as our active tests showed.
#
# RUN AS ADMINISTRATOR, app (this VPN app) CLOSED. Self-relaunches to 64-bit. No internet needed.

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
  [DllImport("WinDivert.dll", SetLastError=true)] public static extern bool WinDivertRecv(IntPtr h, byte[] p, uint n, out uint r, byte[] a);
  [DllImport("WinDivert.dll", SetLastError=true)] public static extern bool WinDivertClose(IntPtr h);
  public static List<string> Log=new List<string>(); public static volatile bool Run=true;
  public static void RecvLoop(IntPtr h){ byte[] pkt=new byte[2048]; byte[] addr=new byte[128]; uint rl;
    while(Run){ if(!WinDivertRecv(h,pkt,(uint)pkt.Length,out rl,addr)) break; if(rl<20) continue;
      int ihl=(pkt[0]&0x0F)*4; int proto=pkt[9];
      string src=pkt[12]+"."+pkt[13]+"."+pkt[14]+"."+pkt[15]; string dst=pkt[16]+"."+pkt[17]+"."+pkt[18]+"."+pkt[19];
      string ev="src="+src+" dst="+dst;
      if(proto==6 && rl>=ihl+14){ ev+=" sport="+((pkt[ihl]<<8)|pkt[ihl+1])+" dport="+((pkt[ihl+2]<<8)|pkt[ihl+3])+" flags=0x"+pkt[ihl+13].ToString("X2"); }
      lock(Log){ Log.Add(ev); } } }
  public static void StartRecv(IntPtr h){ var t=new Thread(()=>RecvLoop(h)); t.IsBackground=true; t.Start(); }
  public static string[] Drain(){ lock(Log){ var a=Log.ToArray(); Log.Clear(); return a; } }
}
'@
Add-Type -TypeDefinition $cs
function U32($ip){ $b=$ip -split '\.'; return ([uint32]$b[0]-shl 24)-bor([uint32]$b[1]-shl 16)-bor([uint32]$b[2]-shl 8)-bor[uint32]$b[3] }
$tgRanges=@(
  @(U32 '149.154.160.0'),(U32 '149.154.175.255'),
  @(U32 '91.108.4.0'),(U32 '91.108.23.255'),
  @(U32 '91.108.56.0'),(U32 '91.108.59.255'),
  @(U32 '95.161.64.0'),(U32 '95.161.79.255'),
  @(U32 '91.105.192.0'),(U32 '91.105.193.255'),
  @(U32 '185.76.151.0'),(U32 '185.76.151.255'))
function InTg($ip){ $v=U32 $ip; for($i=0;$i -lt $tgRanges.Count;$i+=2){ if($v -ge $tgRanges[$i] -and $v -le $tgRanges[$i+1]){ return $true } }; return $false }
$u=New-Object System.Net.Sockets.UdpClient;$u.Connect('1.1.1.1',53);$myip=$u.Client.LocalEndPoint.Address.ToString();$u.Close()

# SNIFF (flag 1): copy packets, do NOT divert/drop -> zero disruption to real traffic.
$h=[WD]::WinDivertOpen('tcp and (tcp.Syn or tcp.Rst or tcp.Fin)',0,0,1)
if($h.ToInt64() -eq -1){Write-Host 'open fail (need admin + WinDivert driver)';exit 1}
[WD]::StartRecv($h)

Write-Output "myip=$myip   watching Telegram ranges for 70s (SNIFF, non-intrusive)"
Write-Output '>>> NOW open Telegram Desktop (no VPN) and let it try to connect. <<<'
Write-Output ''
$seenOut=@{}; $gotSynAck=$false; $tgIps=@{}
for($s=0;$s -lt 70;$s++){
  Start-Sleep -Seconds 1; $ev=[WD]::Drain()
  foreach($line in $ev){
    if($line -notmatch '^src=([0-9.]+) dst=([0-9.]+)'){ continue }
    $src=$matches[1]; $dst=$matches[2]
    $out = ($src -eq $myip)
    $remote = if($out){ $dst } else { $src }
    if(-not (InTg $remote)){ continue }
    $fl=0; if($line -match 'flags=0x([0-9A-Fa-f]{2})'){ $fl=[Convert]::ToInt32($matches[1],16) }
    $rport = if($out){ if($line -match 'dport=([0-9]+)'){ $matches[1] } else { '?' } } else { if($line -match 'sport=([0-9]+)'){ $matches[1] } else { '?' } }
    $tgIps[$remote]=$true
    if($out -and (($fl -band 0x12) -eq 0x02)){
      $k="$remote`:$rport"; if(-not $seenOut.ContainsKey($k)){ $seenOut[$k]=$true; Write-Host ("  [{0,2}s] OUT SYN     -> {1}" -f $s,$k) -ForegroundColor Yellow }
    }
    elseif((-not $out) -and (($fl -band 0x12) -eq 0x12)){
      Write-Host ("  [{0,2}s] IN  SYN-ACK <- {1}:{2}  *** TELEGRAM ANSWERED -- WORKING PATH ***" -f $s,$remote,$rport) -ForegroundColor Green; $gotSynAck=$true
    }
    elseif((-not $out) -and (($fl -band 0x04) -ne 0)){
      Write-Host ("  [{0,2}s] IN  RST     <- {1}:{2}" -f $s,$remote,$rport) -ForegroundColor DarkYellow
    }
  }
}
[WD]::Run=$false; Start-Sleep -Milliseconds 300; [void][WD]::WinDivertClose($h)
Write-Output ''
Write-Output '========================== VERDICT =========================='
Write-Output ("  Telegram IPs the client touched: {0}" -f $(if($tgIps.Count){ ($tgIps.Keys -join ', ') } else { 'NONE (client made no TG connection attempt -- not running / using VPN / cached fail)' }))
if($gotSynAck){ Write-Output '  WORKING PATH FOUND: a Telegram IP sent a SYN-ACK to the real client -> copy that exact IP:port'; Write-Output '  (the dropper is NOT covering it) and we pin it. THIS is the server-less route.' }
elseif($tgIps.Count){ Write-Output '  The client tried Telegram IP(s) but got NO SYN-ACK (only RST/silence) -> same wall our active'; Write-Output '  tests hit: every TG SYN is dropped. Confirms the block is total at the TCP layer on this machine.' }
else { Write-Output '  The client made ZERO TG connection attempts in the window -> it was not actually trying (closed,'; Write-Output '  or routing via the app/VPN/a configured proxy). Re-run and click around in Telegram to force retries.' }
Write-Output '============================================================='
