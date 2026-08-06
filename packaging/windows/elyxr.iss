; elyxr.iss — the Windows installer.
;
; Produces elyxr-setup.exe: a one-click, per-user install (no admin) that mirrors
; what elyxr.sh does on Linux — drops the app and lymnal in place, puts elyxr in
; the Start menu, and registers lymnal to run hidden at every login (the
; always-on service), so the trove is reachable with the app closed and updates
; land on their own. Re-running it (which the auto-updater does with /VERYSILENT)
; is an update: it stops lymnal, swaps the binaries, and starts it again.
;
; CI stages the build into packaging\windows\stage\ before compiling this, and
; passes the build number as /DAppVer=<n>.

#ifndef AppVer
  #define AppVer "0"
#endif

[Setup]
; A fixed AppId so updates replace the same install instead of stacking.
AppId={{A7E1F3C2-9B4D-4E6A-8F1B-2C3D4E5F6A7B}
AppName=elyxr
AppVersion={#AppVer}
AppPublisher=elyxr
DefaultDirName={autopf}\elyxr
DefaultGroupName=elyxr
DisableProgramGroupPage=yes
DisableDirPage=auto
; Per-user, no admin — the same "a routine update never needs a password" that
; the Linux user service gives. Installs under %LOCALAPPDATA%\Programs\elyxr.
PrivilegesRequired=lowest
OutputDir=.
OutputBaseFilename=elyxr-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Files]
; The app bundle (elyxr.exe + its DLLs + data\) and lymnal.exe, staged by CI…
Source: "stage\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion
; …and the hidden launcher for the login task.
Source: "lymnal-launch.vbs"; DestDir: "{app}"; Flags: ignoreversion
; The starter config template — seeded into the user's config on first install
; (see CurStepChanged) so this device can serve the trove, exactly like Linux.
Source: "..\..\config.example.toml"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
; Start menu shortcut for the app.
Name: "{group}\elyxr"; Filename: "{app}\elyxr.exe"
Name: "{autoprograms}\elyxr"; Filename: "{app}\elyxr.exe"
; Run lymnal hidden at login — the always-on service. A shortcut to the .vbs in
; the Startup folder is per-user and needs no admin; the script keeps the console
; window hidden.
Name: "{userstartup}\elyxr lymnal"; Filename: "wscript.exe"; Parameters: """{app}\lymnal-launch.vbs"""

[Run]
; Start lymnal now, hidden, so the service is up without waiting for a re-login —
; including after a silent auto-update, which is why this isn't skipifsilent.
Filename: "wscript.exe"; Parameters: """{app}\lymnal-launch.vbs"""; Flags: nowait runhidden
; Offer to open the app after a normal (non-silent) install.
Filename: "{app}\elyxr.exe"; Description: "Open elyxr"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Stop the service and drop its login entry on uninstall.
Filename: "{sys}\taskkill.exe"; Parameters: "/im lymnal.exe /f"; Flags: runhidden; RunOnceId: "stoplymnal"

[Code]
// Before files are written — including on a silent auto-update — stop any
// running lymnal so its exe isn't locked and can be replaced.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  rc: Integer;
begin
  Exec('taskkill.exe', '/im lymnal.exe /f', '', SW_HIDE, ewWaitUntilTerminated, rc);
  Result := '';
end;

// After install, seed the lymnal config from the template if the user has none
// yet — the same first-run copy elyxr.sh does on Linux — so this device can act
// as a server (serve mode reads a config; a client just ignores it). Left alone
// on later updates so a customised config is never clobbered. The path matches
// lymnal's home_dir (%USERPROFILE% on Windows).
procedure CurStepChanged(CurStep: TSetupStep);
var
  cfgDir, cfg, tmpl: String;
begin
  if CurStep = ssPostInstall then begin
    cfgDir := ExpandConstant('{userprofile}\.config\lymnal');
    cfg := cfgDir + '\config.toml';
    if not FileExists(cfg) then begin
      ForceDirectories(cfgDir);
      tmpl := ExpandConstant('{app}\config.example.toml');
      FileCopy(tmpl, cfg, True);
    end;
  end;
end;
