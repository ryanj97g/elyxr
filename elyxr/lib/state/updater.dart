// Runs `lymnal update` from inside the app, then closes and reopens the app on
// its own once the rebuild is done — no button, no confirmation. Each device
// updates itself from the repository (`lymnal update` → git), never from another
// device; the server only tells a client to start.
//
// The rebuild replaces the app's own files, so it can't happen in place — the
// running app keeps its old copy while the new one lands beside it, and the
// relaunch is what steps onto the new build. The relaunch is automatic and
// silent, with one exception: if a file is mid-upload, it waits for that upload
// to finish first (the server keeps upload state in memory, so restarting
// mid-upload would lose it), then relaunches the instant it's done.

import 'dart:io';

import 'package:flutter/foundation.dart';

import 'transfers.dart';

enum UpdateStage { idle, updating, waitingForUpload, failed }

class UpdateController extends ChangeNotifier {
  final TransferController _transfers;
  UpdateController(this._transfers);

  UpdateStage stage = UpdateStage.idle;
  String? error;
  int _actingOnBuild = 0;

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
    stage = UpdateStage.updating;
    error = null;
    notifyListeners();
    try {
      final proc = await Process.start(_bin('lymnal'), ['update']);
      proc.stdout.listen((_) {});
      proc.stderr.listen((_) {});
      final code = await proc.exitCode;
      if (code == 0) {
        await _relaunchWhenClear();
      } else {
        stage = UpdateStage.failed;
        error = 'The update didn\'t finish (exit $code).';
        notifyListeners();
      }
    } catch (e) {
      stage = UpdateStage.failed;
      error = 'Could not run the update: $e';
      notifyListeners();
    }
  }

  /// Relaunch onto the fresh build now, or the instant an in-flight upload ends.
  Future<void> _relaunchWhenClear() async {
    while (_transfers.hasPendingUpload) {
      if (stage != UpdateStage.waitingForUpload) {
        stage = UpdateStage.waitingForUpload;
        notifyListeners();
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    await _relaunch();
  }

  Future<void> _relaunch() async {
    try {
      final exe = Platform.resolvedExecutable;
      if (File(exe).existsSync()) {
        await Process.start(exe, const [], mode: ProcessStartMode.detached);
      }
    } catch (_) {
      // If relaunch can't spawn, the person reopens elyxr themselves — the new
      // build is already in place.
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(0);
  }

  /// Retry after a failed update.
  void retry() {
    if (busy) return;
    _run();
  }
}
