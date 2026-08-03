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
CloseApplicationsFilter=OPLFleetAgent.exe;CodexTPS.exe
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

[InstallDelete]
Type: files; Name: "{autoprograms}\Codex TPS.lnk"
Type: files; Name: "{autodesktop}\Codex TPS.lnk"

[Run]
Filename: "{app}\OPLFleetAgent.exe"; Parameters: "--background"; Description: "{cm:LaunchProgram,OPL Fleet Agent}"; Flags: nowait postinstall skipifsilent

[Code]
var
  LegacyBridgePath: string;

procedure InitializeWizard;
var
  CurrentInstallDirectory: string;
begin
  LegacyBridgePath := ExpandConstant('{param:LEGACYBRIDGEPATH|}');
  if LegacyBridgePath <> '' then
  begin
    if CompareText(ExtractFileName(LegacyBridgePath), 'CodexTPS.exe') <> 0 then
      RaiseException('The legacy upgrade bridge path is invalid.');
    if not FileExists(LegacyBridgePath) then
      RaiseException('The legacy upgrade executable does not exist.');
    exit;
  end;

  CurrentInstallDirectory := WizardForm.DirEdit.Text;
  if FileExists(AddBackslash(CurrentInstallDirectory) + 'CodexTPS.exe') then
  begin
    LegacyBridgePath := AddBackslash(CurrentInstallDirectory) + 'CodexTPS.exe';
    WizardForm.DirEdit.Text := ExpandConstant('{localappdata}\Programs\OPL Fleet Agent');
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssPostInstall) and (LegacyBridgePath <> '') then
  begin
    ForceDirectories(ExtractFileDir(LegacyBridgePath));
    if not FileCopy(
        ExpandConstant('{app}\OPLFleetAgent.exe'),
        LegacyBridgePath,
        False) then
      RaiseException('Unable to create the one-time Codex TPS upgrade bridge.');
  end;
end;

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
