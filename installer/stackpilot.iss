#define AppName "StackPilot"
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#define AppPublisher "StackPilot"
#define AppExeName "stackpilot.exe"
#ifndef AppChannel
  #define AppChannel "stable"
#endif
#ifndef AppNumericVersion
  #define AppNumericVersion AppVersion
#endif

[Setup]
AppId={{90568960-EF7E-4F8F-A47A-C9D111B78D38}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={localappdata}\Programs\StackPilot
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
DisableDirPage=no
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\build\installer
OutputBaseFilename=StackPilot-{#AppVersion}-Setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes
RestartApplications=no
SetupLogging=yes
VersionInfoVersion={#AppNumericVersion}
VersionInfoCompany={#AppPublisher}
VersionInfoProductName={#AppName}
VersionInfoDescription={#AppName} {#AppChannel} installer

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
#ifdef PayloadDir
; Optional offline payload. payload.json decides which archives are trusted;
; the catalog checksum is verified again before anything is extracted.
Source: "{#PayloadDir}\*"; DestDir: "{app}\payload"; Flags: ignoreversion recursesubdirs createallsubdirs
#endif

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[Code]
{ StackPilot asks for the two things that used to be missing from this
  installer: where stacks live and which components to download. Nothing is
  downloaded here; the answers are written to preferences.json so the app's
  first launch opens the setup wizard pre-filled. }

const
  MaxComponents = 8;

var
  StacksPage: TInputDirWizardPage;
  DownloadPage: TInputOptionWizardPage;
  ComponentsPage: TInputOptionWizardPage;
  ComponentKeys: array[0..MaxComponents - 1] of String;
  ComponentLabels: array[0..MaxComponents - 1] of String;

procedure DefineComponents();
begin
  ComponentKeys[0] := 'php';
  ComponentLabels[0] := 'PHP (thread-safe, loaded by Apache)';

  ComponentKeys[1] := 'apache';
  ComponentLabels[1] := 'Apache HTTP Server';

  ComponentKeys[2] := 'mysql';
  ComponentLabels[2] := 'MariaDB (MySQL-compatible database)';

  ComponentKeys[3] := 'mailpit';
  ComponentLabels[3] := 'Mailpit (catches outgoing mail)';

  ComponentKeys[4] := 'nginx';
  ComponentLabels[4] := 'Nginx (alternative web server)';

  ComponentKeys[5] := 'nodejs';
  ComponentLabels[5] := 'Node.js with npm';

  ComponentKeys[6] := 'redis';
  ComponentLabels[6] := 'Redis';

  ComponentKeys[7] := 'postgresql';
  ComponentLabels[7] := 'PostgreSQL';
end;

procedure InitializeWizard();
var
  Index: Integer;
begin
  DefineComponents();

  StacksPage := CreateInputDirPage(
    wpSelectDir,
    'Where should your stacks live?',
    'Choose the folder that will contain your stacks.',
    'StackPilot creates one folder per stack, for example ' +
    '"<chosen folder>\default". The folder holds the downloaded binaries, ' +
    'your projects, and the databases, so pick a disk you can back up.',
    False,
    '');
  StacksPage.Add('Stacks folder:');
  StacksPage.Values[0] := ExpandConstant('{localappdata}\StackPilot\stacks');

  DownloadPage := CreateInputOptionPage(
    StacksPage.ID,
    'Component downloads',
    'How should StackPilot get the components you choose?',
    'This installer never downloads anything itself. StackPilot does it on ' +
    'first launch, and you can change the choice later in Settings.',
    True,
    False);
  DownloadPage.Add('Download now, on the first launch');
  DownloadPage.Add('Ask me on the first launch');
  DownloadPage.Add('Do not download - I will add ZIP files myself');
  DownloadPage.Values[0] := True;

  ComponentsPage := CreateInputOptionPage(
    DownloadPage.ID,
    'Components',
    'Which components should this stack start with?',
    'Each component is installed into its own folder inside the stack. ' +
    'Versions can be changed later from the service cards.',
    False,
    True);
  for Index := 0 to MaxComponents - 1 do
    ComponentsPage.Add(ComponentLabels[Index]);

  { PHP, Apache, MariaDB, and Mailpit are the recommended starter stack. }
  ComponentsPage.Values[0] := True;
  ComponentsPage.Values[1] := True;
  ComponentsPage.Values[2] := True;
  ComponentsPage.Values[3] := True;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Folder, Drive: String;
  FreeMB, TotalMB: Cardinal;
begin
  Result := True;
  if CurPageID <> StacksPage.ID then
    Exit;

  Folder := Trim(StacksPage.Values[0]);
  if Folder = '' then
  begin
    MsgBox('Choose a folder for your stacks.', mbError, MB_OK);
    Result := False;
    Exit;
  end;

  Drive := ExtractFileDrive(Folder);
  if Drive <> '' then
  begin
    if GetSpaceOnDisk(Drive, True, FreeMB, TotalMB) then
    begin
      if FreeMB < 500 then
      begin
        MsgBox('That drive has less than 500 MB free. StackPilot needs room ' +
               'for Apache, PHP, a database, and your projects.', mbError, MB_OK);
        Result := False;
      end;
    end;
  end;
end;

function JsonEscape(const Value: String): String;
var
  Index: Integer;
  Character: String;
begin
  Result := '';
  for Index := 1 to Length(Value) do
  begin
    Character := Copy(Value, Index, 1);
    if Character = '\' then
      Result := Result + '\\'
    else if Character = '"' then
      Result := Result + '\"'
    else if Character = #9 then
      Result := Result + '\t'
    else
      Result := Result + Character;
  end;
end;

function SelectedComponentsJson(): String;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to MaxComponents - 1 do
  begin
    if ComponentsPage.Values[Index] then
    begin
      if Result <> '' then
        Result := Result + ', ';
      Result := Result + '"' + JsonEscape(ComponentKeys[Index]) + '"';
    end;
  end;
end;

function DownloadModeId(): String;
begin
  if DownloadPage.Values[2] then
    Result := 'manual'
  else if DownloadPage.Values[1] then
    Result := 'onFirstRun'
  else
    Result := 'now';
end;

procedure WritePreferences();
var
  PreferencesPath, Folder, Directory, Json: String;
begin
  PreferencesPath := ExpandConstant('{userappdata}\StackPilot\preferences.json');

  { An update keeps the settings the user already has. }
  if FileExists(PreferencesPath) then
  begin
    Folder := RemoveBackslashUnlessRoot(StacksPage.Values[0]);
    if not DirExists(Folder) then
      ForceDirectories(Folder);
    Exit;
  end;

  Folder := RemoveBackslashUnlessRoot(StacksPage.Values[0]);
  Directory := ExtractFileDir(PreferencesPath);
  if not DirExists(Directory) then
    ForceDirectories(Directory);
  if not DirExists(Folder) then
    ForceDirectories(Folder);

  Json :=
    '{' + #13#10 +
    '  "stacksFolder": "' + JsonEscape(Folder) + '",' + #13#10 +
    '  "minimizeToTray": true,' + #13#10 +
    '  "onboardingCompleted": false,' + #13#10 +
    '  "pendingComponents": [' + SelectedComponentsJson() + '],' + #13#10 +
    '  "pendingDownloadMode": "' + DownloadModeId() + '"' + #13#10 +
    '}' + #13#10;

  if not SaveStringToFile(PreferencesPath, Json, False) then
    MsgBox('StackPilot could not write ' + PreferencesPath + '. The app will ' +
           'ask for these choices on first launch instead.', mbInformation, MB_OK);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    WritePreferences();
end;
