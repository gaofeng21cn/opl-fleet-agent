#define AppVersion GetEnv("OPL_FLEET_AGENT_INSTALLER_VERSION")
#define AppVersionQuad GetEnv("OPL_FLEET_AGENT_INSTALLER_VERSION_QUAD")
#define SourceDir GetEnv("OPL_FLEET_AGENT_INSTALLER_SOURCE")
#define OutputDir GetEnv("OPL_FLEET_AGENT_INSTALLER_OUTPUT")

#if AppVersion == ""
  #error OPL_FLEET_AGENT_INSTALLER_VERSION is required
#endif
#if SourceDir == ""
  #error OPL_FLEET_AGENT_INSTALLER_SOURCE is required
#endif
#if OutputDir == ""
  #error OPL_FLEET_AGENT_INSTALLER_OUTPUT is required
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
OutputBaseFilename=OPL-Fleet-Agent-Windows-win-x64-Setup
SetupIconFile={#SourceDir}\app.ico
UninstallDisplayIcon={app}\OPLFleetAgent.exe
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
CloseApplications=yes
CloseApplicationsFilter=OPLFleetAgent.exe
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
Name: "{autoprograms}\OPL Fleet Agent"; Filename: "{app}\OPLFleetAgent.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\OPL Fleet Agent"; Filename: "{app}\OPLFleetAgent.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\OPLFleetAgent.exe"; Parameters: "--background"; Description: "{cm:LaunchProgram,OPL Fleet Agent}"; Flags: nowait postinstall skipifsilent

[Code]
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    RegDeleteValue(
      HKCU,
      'Software\Microsoft\Windows\CurrentVersion\Run',
      'OPL Fleet Agent');
end;
