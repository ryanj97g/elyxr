// Runs `lymnal update` from inside the app, then closes and reopens the app on
// its own once the rebuild is done — no button, no confirmation. Updates are
// bidirectional: pressing update on any owner device updates the whole fleet.
// On the server that means rebuild-then-announce; on a client it asks the server
// to update everyone (the server broadcasts and updates itself), and this
// device's own agent applies the update in the background and restarts the app.
//
// Android is the exception: it can't rebuild or silently self-replace, so it
// updates the Android-legal way — download the published APK and hand it to the
// system package installer, which asks the user to Install (one tap). Every
// build is signed with the same key, so it installs in place over the old one.
//
// The rebuild replaces the app's own files, so it can't happen in place — the
// running app keeps its old copy while the new one lands beside it, and the
// relaunch is what steps onto the new build. The relaunch is automatic and
// silent, with one exception: if a file is mid-upload, it waits for that upload
// to finish first (the server keeps upload state in memory, so restarting
// mid-upload would lose it), then relaunches the instant it's done.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../util/platform_caps.dart';

enum UpdateStage { idle, updating, waitingForUpload, failed }

class UpdateController extends ChangeNotifier {
  UpdateController();

  UpdateStage stage = UpdateStage.idle;
  String? error;
  int _actingOnBuild = 0;
  // Guards the "updating" spinner on the client fleet-request path, where the
  // background agent (not this process) applies the update and restarts the app.
  Timer? _fleetTimeout;

  bool get busy => stage == UpdateStage.updating || stage == UpdateStage.waitingForUpload;

  String _bin(String name) {
    final home = Platform.environment['HOME'];
    for (final path in [
      if (home != null) '$home/.local/bin/$name',
      '/usr/local/bin/$name',
    ]) {
      if (File(path).existsSync()) return path;
    }
    return name;
  }

  /// Called with the server's build when this client learns it's behind. Starts
  /// once per newer build; ignores repeat news while one is already running.
  void noticeBehind(int serverBuild) {
    if (busy) return;
    if (serverBuild <= _actingOnBuild) return;
    _actingOnBuild = serverBuild;
    _run();
  }

  /// Trigger the update by hand (the server's "update now", or the client acting
  /// on the server's live announcement).
  void updateNow() {
    if (busy) return;
    _run();
  }

  /// The published APK the Android in-app updater fetches. A stable release
  /// asset (never the repo's "latest" release, so it can't shadow the Windows
  /// installer), rebuilt on every push to main.
  static const _androidApkUrl =
      'https://github.com/ryanj97g/elyxr/releases/download/android-latest/elyxr.apk';

  Future<void> _run() async {
    // Android can't rebuild itself and can't silently self-replace, but it can
    // do it the legal way: download the new APK and hand it to the system
    // package installer, which prompts the user to Install (one tap). Every
    // build is signed with the same key, so it installs over the top in place.
    if (Caps.isAndroid) {
      stage = UpdateStage.updating;
      error = null;
      notifyListeners();
      try {
        final dir = await getTemporaryDirectory();
        final f = File('${dir.path}/elyxr-update.apk');
        final client = http.Client();
        final resp = await client.send(http.Request('GET', Uri.parse(_androidApkUrl)));
        if (resp.statusCode != 200) {
          client.close();
          throw 'HTTP ${resp.statusCode}';
        }
        final sink = f.openWrite();
        await resp.stream.pipe(sink);
        await sink.close();
        client.close();
        final res = await OpenFilex.open(
          f.path,
          type: 'application/vnd.android.package-archive',
        );
        if (res.type == ResultType.done) {
          // The system installer has it now; nothing left for us to drive.
          stage = UpdateStage.idle;
        } else {
          stage = UpdateStage.failed;
          error = 'Couldn\'t open the installer: ${res.message}';
        }
        notifyListeners();
      } catch (e) {
        stage = UpdateStage.failed;
        error = 'Update download failed: $e';
        notifyListeners();
      }
      return;
    }
    // Any other no-exec platform (e.g. iOS): there's nothing to fetch.
    if (!Caps.canExec) {
      stage = UpdateStage.failed;
      error = 'Update elyxr from the app store (or install the latest APK).';
      notifyListeners();
      return;
    }
    stage = UpdateStage.updating;
    error = null;
    notifyListeners();
    try {
      final proc = await Process.start(_bin('lymnal'), ['update']);
      proc.stdout.listen((_) {});
      proc.stderr.listen((_) {});
      final code = await proc.exitCode;
      if (code == 0) {
        // The update is launched. It runs detached (its own systemd scope),
        // rebuilds, and restarts this app when the new build is ready — so we
        // stay on "updating" and let that restart happen. This is the exact same
        // path the tray's "Update now" and `lymnal update` take.
        _fleetTimeout?.cancel();
        _fleetTimeout = Timer(const Duration(minutes: 10), () {
          if (stage == UpdateStage.updating) {
            stage = UpdateStage.idle;
            notifyListeners();
          }
        });
      } else {
        stage = UpdateStage.failed;
        error = 'The update didn\'t start (exit $code).';
        notifyListeners();
      }
    } catch (e) {
      stage = UpdateStage.failed;
      error = 'Could not start the update: $e';
      notifyListeners();
    }
  }

  /// Retry after a failed update.
  void retry() {
    if (busy) return;
    _run();
  }
}
