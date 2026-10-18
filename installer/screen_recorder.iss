; One-click installer for Screen Recorder (Windows).
;
; Installs per-user (no admin prompt) into %LOCALAPPDATA%\Programs, puts a
; shortcut on the Desktop and in the Start menu, and offers to launch the app.
; FFmpeg and the VC++ runtime DLLs are bundled, so nothing else is needed.
;
; Build:  iscc /DAppVersion=1.0.0 installer\screen_recorder.iss
; Updates: the app downloads a newer copy of this installer and runs it with
;          /SILENT /SUPPRESSMSGBOXES /CLOSEAPPLICATIONS /update=1 (same AppId,
;          so it upgrades in place and keeps settings).

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#define AppName "Screen Recorder"
#define AppExe "screen_recorder_app.exe"
#define SourceDir "..\build\windows\x64\runner\Release"

[Setup]
AppId={{8F3C2B71-5E0A-4D8B-9C61-2A7E4B1D9F30}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppName}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
PrivilegesRequired=lowest
DisableWelcomePage=yes
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
CloseApplications=yes
OutputDir=..\dist
OutputBaseFilename=ScreenRecorder-Setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
MinVersion=10.0.17763

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"

[Run]
Filename: "{app}\{#AppExe}"; Description: "Open {#AppName} now"; Flags: nowait postinstall skipifsilent
; In-app updates run this installer with /SILENT /update=1: reopen the app afterwards.
Filename: "{app}\{#AppExe}"; Flags: nowait; Check: IsAppUpdate

[Code]
function IsAppUpdate: Boolean;
begin
  Result := ExpandConstant('{param:update|0}') = '1';
end;

[UninstallDelete]
Type: filesandordirs; Name: "{userappdata}\screen_recorder_app"
