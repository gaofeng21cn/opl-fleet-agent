#define AppVersion GetEnv("CODEX_TPS_INSTALLER_VERSION")
#define AppVersionQuad GetEnv("CODEX_TPS_INSTALLER_VERSION_QUAD")
#define SourceDir GetEnv("CODEX_TPS_INSTALLER_SOURCE")
#define OutputDir GetEnv("CODEX_TPS_INSTALLER_OUTPUT")

#if AppVersion == ""
  #error CODEX_TPS_INSTALLER_VERSION is required
#endif
#if SourceDir == ""
  #error CODEX_TPS_INSTALLER_SOURCE is required
#endif
#if OutputDir == ""
  #error CODEX_TPS_INSTALLER_OUTPUT is required
#endif

[Setup]
AppId={{F83F1225-9AFB-4C72-AD2B-80E43AF81672}
AppName=OPL Fleet Agent
AppVersion={#AppVersion}
AppVerName=OPL Fleet Agent {#AppVersion}
AppPublisher=Feng Gao
AppPublisherURL=https://github.com/gaofeng21cn/opl-fleet-agent
AppSupportURL=https://github.com/gaofeng21cn/opl-fleet-agent/issues
AppUpdatesURL=https://github.com/gaofeng21cn/opl-fleet-agent/releases/latest
VersionInfoVersion={#AppVersionQuad}
DefaultDirName={localappdata}\Programs\OPL Fleet Agent
DefaultGroupName=OPL Fleet Agent
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=Codex-TPS-Windows-win-x64-Setup
SetupIconFile={#SourceDir}\app.ico
UninstallDisplayIcon={app}\CodexTPS.exe
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
CloseApplications=yes
CloseApplicationsFilter=CodexTPS.exe
RestartApplications=no
SetupLogging=yes
LicenseFile={#SourceDir}\LICENSE.txt

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\OPL Fleet Agent"; Filename: "{app}\CodexTPS.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\OPL Fleet Agent"; Filename: "{app}\CodexTPS.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[InstallDelete]
Type: files; Name: "{autoprograms}\Codex TPS.lnk"
Type: files; Name: "{autodesktop}\Codex TPS.lnk"

[Run]
Filename: "{app}\CodexTPS.exe"; Parameters: "--background"; Description: "{cm:LaunchProgram,OPL Fleet Agent}"; Flags: nowait postinstall skipifsilent

[Code]
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    RegDeleteValue(
      HKCU,
      'Software\Microsoft\Windows\CurrentVersion\Run',
      'OPL Fleet Agent');
    RegDeleteValue(
      HKCU,
      'Software\Microsoft\Windows\CurrentVersion\Run',
      'Codex TPS');
end;
