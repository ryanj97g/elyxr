// Runs `lymnal update` from inside the app, then closes and reopens the app on
// its own once the rebuild is done — no button, no confirmation. Updates are
// bidirectional: pressing update on any owner device updates the whole fleet.
// On the server that means rebuild-then-announce; on a client it asks the server
// to update everyone (the server broadcasts and updates itself), and this
// device's own agent applies the update in the background and restarts the app.
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

  Future<void> _run() async {
    // A phone can't shell out to `lymnal update`; it updates from the app store
    // or a new APK. Report that rather than throwing.
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
