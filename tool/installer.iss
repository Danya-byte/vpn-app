; Inno Setup script for VPN App - a proper Windows installer (Start-menu +
; desktop shortcuts, optional run-at-login, clean uninstall) so non-technical
; RF users don't have to unzip-to-Program-Files by hand.
;
; Build:  iscc tool\installer.iss            (uses build\...\Release as source)
;         iscc /DAppVer=1.0.0 tool\installer.iss
; Ships unsigned (open-source; the release .sha256 is the integrity check).

#ifndef AppVer
  #define AppVer "1.0.0"
#endif
#define AppName "VPN App"
#define AppPublisher "Danya-byte"
#define AppExe "vpn_app.exe"
#define SourceDir "..\build\windows\x64\runner\Release"

; Fail the build EARLY if the cores aren't bundled - someone ran `iscc` directly
; instead of tool\package.ps1 (which fetches the SHA-256-pinned sing-box+xray).
; Otherwise the installer would ship a coreless app that can't connect at all.
#if !FileExists(SourceDir + "\core\windows\sing-box.exe")
  #error Cores missing in SourceDir. Run tool\package.ps1 (or fetch-cores.ps1) before iscc.
#endif
; The desync engine (server-less DPI bypass) must ship too — without winws the
; headline feature is permanently absent in the installed app (audit blocker #1).
#if !FileExists(SourceDir + "\core\windows\winws.exe")
  #error Desync engine missing. Run tool\fetch-cores.ps1 -IncludeXray -IncludeDesync before packaging.
#endif

[Setup]
AppId={{A7E3C92F-4B81-4D6A-9C05-1E2F3A4B5C6D}
AppName={#AppName}
AppVersion={#AppVer}
AppPublisher={#AppPublisher}
AppPublisherURL=https://github.com/Danya-byte/vpn-app
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=vpn_app-setup-{#AppVer}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Per-user by default (no UAC for install); the app self-elevates for TUN mode.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
LicenseFile=..\LICENSE
UninstallDisplayIcon={app}\{#AppExe}

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "autostart"; Description: "Start with Windows"; GroupDescription: "Startup:"; Flags: unchecked

[Files]
; Bundles the whole Release tree: vpn_app.exe + flutter DLLs + core\windows\* +
; core\rule-sets\* + LICENSE/THIRD_PARTY/COPYING (placed there by package.ps1).
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"

[Registry]
; Optional run-at-login (per-user Run key).
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; \
  ValueName: "VPNApp"; ValueData: """{app}\{#AppExe}"""; Tasks: autostart; Flags: uninsdeletevalue

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Remove the generated runtime (config/cache/pids) but keep nothing sensitive behind.
Type: filesandordirs; Name: "{localappdata}\vpn_app\run"

[Code]
const
  InetKey = 'Software\Microsoft\Windows\CurrentVersion\Internet Settings';
  BakKey  = 'Software\vpn_app';
  INTERNET_OPTION_SETTINGS_CHANGED = 39;
  INTERNET_OPTION_REFRESH = 37;

function InternetSetOption(hInet, dwOption, lpBuffer, dwBufLen: Integer): Boolean;
  external 'InternetSetOptionW@wininet.dll stdcall';

function StartsWithLoopback(const s: String): Boolean;
begin
  Result := (Pos('127.0.0.1', s) = 1) or (Pos('localhost', s) = 1);
end;

// Mirror the native RestoreSystemProxy: put the user's ORIGINAL proxy back from
// our backup (so we never strand their real proxy), else just disable a dead
// loopback pointer of OURS, then signal WinINET so it takes effect immediately.
procedure RestoreUserProxy();
var
  bakValid, bakEnable: Cardinal;
  bakServer, bakOverride, curServer: String;
  changed: Boolean;
begin
  changed := False;
  if RegQueryDWordValue(HKCU, BakKey, 'BackupValid', bakValid) and (bakValid = 1) then
  begin
    if not RegQueryDWordValue(HKCU, BakKey, 'BackupEnable', bakEnable) then bakEnable := 0;
    if not RegQueryStringValue(HKCU, BakKey, 'BackupServer', bakServer) then bakServer := '';
    if not RegQueryStringValue(HKCU, BakKey, 'BackupOverride', bakOverride) then bakOverride := '';
    RegWriteDWordValue(HKCU, InetKey, 'ProxyEnable', bakEnable);
    RegWriteStringValue(HKCU, InetKey, 'ProxyServer', bakServer);
    RegWriteStringValue(HKCU, InetKey, 'ProxyOverride', bakOverride);
    RegWriteDWordValue(HKCU, BakKey, 'BackupValid', 0);
    changed := True;
  end
  else if RegQueryStringValue(HKCU, InetKey, 'ProxyServer', curServer)
          and StartsWithLoopback(curServer) then
  begin
    // Anchored (starts-with) so a real third-party proxy that merely mentions
    // 127.0.0.1 in a later protocol field is left untouched.
    RegWriteDWordValue(HKCU, InetKey, 'ProxyEnable', 0);
    changed := True;
  end;
  if changed then
  begin
    InternetSetOption(0, INTERNET_OPTION_SETTINGS_CHANGED, 0, 0);
    InternetSetOption(0, INTERNET_OPTION_REFRESH, 0, 0);
  end;
end;

// Runs AFTER the user clicks Install, BEFORE any file is copied. A reinstall /
// in-place update over a RUNNING app would otherwise hit file locks — most
// critically winws.exe, which keeps the WinDivert kernel driver and its own files
// locked. Kill the app + ALL cores first (mirrors the uninstall cleanup) so an
// update can't fail with "file in use".
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  rc: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'),
    '/F /IM vpn_app.exe /IM sing-box.exe /IM xray.exe /IM winws.exe /IM awg.exe',
    '', SW_HIDE, ewWaitUntilTerminated, rc);
  // Give WinDivert a moment to unload after winws dies so its files unlock.
  Sleep(400);
  Result := '';  // empty = proceed with installation
end;

procedure CurUninstallStepChanged(CurStep: TUninstallStep);
var
  rc: Integer;
begin
  if CurStep = usUninstall then
  begin
    // Kill the app + ALL cores BEFORE removing files: the dynamic WFP kill-switch
    // fence auto-purges with the process, and the .exe/DLLs unlock for deletion.
    // winws.exe MUST be here — it's the server-less desync sidecar this installer
    // ships; if left running it keeps a WinDivert kernel driver loaded, locks its
    // files against deletion, and keeps desyncing live traffic after uninstall.
    // awg.exe is the (optional) AmneziaWG bridge, killed for the same reason.
    Exec(ExpandConstant('{sys}\taskkill.exe'),
      '/F /IM vpn_app.exe /IM sing-box.exe /IM xray.exe /IM winws.exe /IM awg.exe',
      '', SW_HIDE, ewWaitUntilTerminated, rc);
    RestoreUserProxy(); // BEFORE deleting BakKey (it reads the backup)
    // Remove app-written HKCU keys: proxy backup, link/scheme handlers, autostart.
    RegDeleteKeyIncludingSubkeys(HKCU, BakKey);
    RegDeleteKeyIncludingSubkeys(HKCU, 'Software\Classes\vpn');
    RegDeleteKeyIncludingSubkeys(HKCU, 'Software\Classes\sing-box');
    RegDeleteKeyIncludingSubkeys(HKCU, 'Software\Classes\Applications\vpn_app.exe');
    RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'vpn_app');
  end;
end;
