; elyxr.iss — the Windows installer.
;
; Produces elyxr-setup.exe: a one-click, per-user install (no admin) that mirrors
; what elyxr.sh does on Linux — drops the app and lymnal in place, puts elyxr in
; the Start menu, and registers lymnal to run hidden at every login (the
; always-on service), so the trove is reachable with the app closed and updates
; land on their own.
;
; Re-running it (which the auto-updater does with /VERYSILENT) is an update AND a
; repair: it stops the app and lymnal, deletes the whole previous payload, writes
; the new one, and starts the service again. Deleting first rather than writing
; over the top is what makes a damaged or half-updated install heal instead of
; staying broken — see [InstallDelete].
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
; How the install shows up in Settings > Apps, and what its uninstaller is called
; there. Inno always builds an uninstaller; these make it identifiable.
UninstallDisplayName=elyxr
UninstallDisplayIcon={app}\elyxr.exe
; One installer at a time. Without this, the silent auto-updater firing while
; someone runs setup by hand gives two processes writing the same files.
SetupMutex=elyxr_setup_mutex

[InstallDelete]
; Runs BEFORE the new files are written, so re-running setup is a clean replace
; rather than an overlay. Without it a file that shipped in an older version and
; no longer exists would survive forever — for a Flutter bundle that means stale
; assets and mismatched DLLs, which is exactly the "install is broken, reinstall
; didn't fix it" case.
;
; Targeted deliberately, NOT a blanket wipe of {app}: the uninstaller
; (unins000.exe/.dat) lives in there and deleting it would orphan the entry in
; Settings > Apps. Everything listed here is payload this installer put there.
Type: filesandordirs; Name: "{app}\data"
Type: files; Name: "{app}\*.dll"
Type: files; Name: "{app}\elyxr.exe"
Type: files; Name: "{app}\lymnal.exe"
Type: files; Name: "{app}\lymnal-launch.vbs"
Type: files; Name: "{app}\config.example.toml"

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
; Uninstall from the Start menu as well as from Settings > Apps — the uninstaller
; has always been built, it just had no way in from where people look for it.
Name: "{group}\Uninstall elyxr"; Filename: "{uninstallexe}"

[Run]
; Start lymnal now, hidden, so the service is up without waiting for a re-login —
; including after a silent auto-update, which is why this isn't skipifsilent.
Filename: "wscript.exe"; Parameters: """{app}\lymnal-launch.vbs"""; Flags: nowait runhidden
; Offer to open the app after a normal (non-silent) install.
Filename: "{app}\elyxr.exe"; Description: "Open elyxr"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Stop the service and the app before their files go, so nothing is left running
; against a half-deleted install.
Filename: "{sys}\taskkill.exe"; Parameters: "/im lymnal.exe /f"; Flags: runhidden; RunOnceId: "stoplymnal"
Filename: "{sys}\taskkill.exe"; Parameters: "/im elyxr.exe /f"; Flags: runhidden; RunOnceId: "stopelyxr"

[UninstallDelete]
; Anything left in the install folder that this installer didn't put there (a log,
; a crash dump). Runs last, after the tracked files are gone, so it only ever
; removes what remains.
Type: filesandordirs; Name: "{app}"

[Code]
// Before files are written — including on a silent auto-update — stop anything
// holding the files we're about to replace. lymnal was always stopped here; the
// app itself wasn't, so updating while elyxr was open left elyxr.exe locked and
// the install half-applied. Both are killed now, which is also what makes a
// re-run able to repair a broken install rather than trip over it.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  rc: Integer;
begin
  Exec('taskkill.exe', '/im lymnal.exe /f', '', SW_HIDE, ewWaitUntilTerminated, rc);
  Exec('taskkill.exe', '/im elyxr.exe /f', '', SW_HIDE, ewWaitUntilTerminated, rc);
  Result := '';
end;

// Is the Tailscale CLI already present? It installs to Program Files.
function TailscaleInstalled(): Boolean;
begin
  Result := FileExists(ExpandConstant('{commonpf}\Tailscale\tailscale.exe')) or
            FileExists(ExpandConstant('{sd}\Program Files\Tailscale\tailscale.exe'));
end;

// elyxr reaches your other devices over Tailscale, so a device with elyxr needs
// it — exactly like elyxr.sh installs it on Linux. Install it through winget
// (present on current Windows; it knows the current version and prompts for the
// one elevation Tailscale needs). If winget isn't available, open the official
// download page so it can be finished by hand rather than failing silently.
// Signing in is the one step no installer can do for you, on either OS.
procedure EnsureTailscale();
var
  rc: Integer;
begin
  if TailscaleInstalled() then
    exit;
  if Exec(ExpandConstant('{cmd}'),
       '/c winget install --id tailscale.tailscale -e --silent ' +
       '--accept-source-agreements --accept-package-agreements',
       '', SW_SHOW, ewWaitUntilTerminated, rc) and (rc = 0) then
    exit;
  ShellExec('open', 'https://tailscale.com/download/windows', '', '', SW_SHOW,
    ewNoWait, rc);
end;

// After install, seed the lymnal config from the template if the user has none
// yet — the same first-run copy elyxr.sh does on Linux — so this device can act
// as a server (serve mode reads a config; a client just ignores it). Left alone
// on later updates so a customised config is never clobbered. The path matches
// lymnal's home_dir (%USERPROFILE% on Windows). Then make sure Tailscale is
// present. Both are skipped on a silent auto-update — that's an existing install,
// already set up.
procedure CurStepChanged(CurStep: TSetupStep);
var
  cfgDir, cfg, tmpl: String;
begin
  if CurStep = ssPostInstall then begin
    cfgDir := ExpandConstant('{%USERPROFILE}\.config\lymnal');
    cfg := cfgDir + '\config.toml';
    if not FileExists(cfg) then begin
      ForceDirectories(cfgDir);
      tmpl := ExpandConstant('{app}\config.example.toml');
      FileCopy(tmpl, cfg, True);
    end;
    if not WizardSilent() then
      EnsureTailscale();
  end;
end;

// ---- uninstall cleanup ----

// The per-user folders lymnal keeps outside the install directory: the config,
// its data dir, and lymbo's cache. Deliberately NOT the trove — that folder is
// the user's own files, which is the entire point of the product, and no
// uninstaller has any business deleting it.
procedure RemoveUserData();
begin
  DelTree(ExpandConstant('{%USERPROFILE}\.config\lymnal'), True, True, True);
  DelTree(ExpandConstant('{%USERPROFILE}\.local\share\lymnal'), True, True, True);
  DelTree(ExpandConstant('{%USERPROFILE}\.cache\lymnal'), True, True, True);
end;

// Offer to take the settings and cache with it. Default is to KEEP them, so
// uninstalling to reinstall doesn't cost the pairing — and the prompt says
// plainly that the trove is never touched, because that's the thing anyone would
// reasonably be afraid of. Silent uninstalls keep everything: an unattended run
// is no place to throw away a user's pairing on an assumption.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep <> usPostUninstall then
    exit;
  if UninstallSilent() then
    exit;
  if MsgBox('Also remove elyxr''s settings, pairing and cached files?' + #13#10#13#10 +
            'Your trove folder and everything in it is left alone either way.' + #13#10#13#10 +
            'Choose No if you plan to reinstall — that keeps this device paired.',
            mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
    RemoveUserData();
end;
