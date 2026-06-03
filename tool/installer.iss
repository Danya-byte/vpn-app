; Inno Setup script for VPN App — a proper Windows installer (Start-menu +
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
