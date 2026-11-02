; Inno Setup script for the Windows build.
;
;   "%LOCALAPPDATA%\Programs\InnoSetup6\ISCC.exe" installer\FreePlayer.iss
;
; Installs per user, never into Program Files: the app replaces its own files
; on update (update.exe) and writes its single-instance lock next to the exe,
; so the install folder has to stay writable without elevation.
;
; Build the payload first:
;   flutter build windows --release --dart-define=FP_APP_VERSION=<version>
;   scripts\assemble.ps1 -FfmpegDir D:\ffmpeg\bin

#define MyAppName "Free Player"
#define MyAppVersion "0.1.3"
#define MyAppWinVersion "0.1.3.0"
#define MyAppPublisher "net900"
#define MyAppURL "https://freeplayer.8a5.cn"
#define MyAppExeName "free_player.exe"
#define PayloadDir "..\shell\build\windows\x64\runner\Release"

[Setup]
AppId={{8F3C2B1A-6D4E-4A7B-9C15-2E8D4F6A1B03}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={localappdata}\Programs\FreePlayer
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=FreePlayer-{#MyAppVersion}-Setup
SetupIconFile=..\shell\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; An in-app update runs this installer silently and then exits; Setup closes
; whatever is left instead of asking (the client is already gone by then).
CloseApplications=force
RestartApplications=no
VersionInfoVersion={#MyAppWinVersion}
VersionInfoProductName={#MyAppName}
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription={#MyAppName} Setup

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; decryptors\ holds the source core downloaded at runtime; packaging it would
; pin one build and ship a file the client is supposed to fetch itself.
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Excludes: "decryptors\*,free_player.lock,*.remove,*.part"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
; Also runs in silent mode: the in-app updater starts this installer instead
; of the portable zip, and the app has to come back by itself afterwards.
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall

[UninstallDelete]
; Written while the app runs, so the uninstall log never knew about them.
Type: files; Name: "{app}\free_player.lock"
Type: filesandordirs; Name: "{app}\decryptors"
