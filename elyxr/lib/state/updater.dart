// Keeps a device up to date the way good desktop apps do: when this client is
// behind the server, it pulls and rebuilds *in the background* while you keep
// working, then — once the new build is ready on disk — invites you to refresh
// whenever you hit a stopping point. Clicking refresh is a near-instant
// relaunch, because the slow part (the rebuild) already happened quietly.
//
// Why background-then-refresh instead of updating in place: rebuilding replaces
// the app's own files. On Linux the running app keeps its old copy in memory
// while the new one lands beside it, so nothing breaks mid-use; the relaunch is
// what actually steps onto the new build. And code always comes from the
// repository (`lymnal update` → git), never from the server — the server only
// tells a client it's behind.

import 'dart:io';

import 'package:flutter/foundation.dart';

enum UpdateStage { idle, updating, readyToRefresh, failed }

class UpdateController extends ChangeNotifier {
  UpdateStage stage = UpdateStage.idle;
  String? error;
  // The build we last acted on, so a running/finished update isn't retriggered
  // by the same version news arriving again.
  int _actingOnBuild = 0;

  bool get busy => stage == UpdateStage.updating;
  bool get ready => stage == UpdateStage.readyToRefresh;

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
  /// a background update once per newer build; ignores repeat news while one is
  /// already running or already staged.
  void noticeBehind(int serverBuild) {
    if (stage == UpdateStage.updating || stage == UpdateStage.readyToRefresh) return;
    if (serverBuild <= _actingOnBuild) return;
    _actingOnBuild = serverBuild;
    _runBackground();
  }

  /// Trigger the background update by hand (e.g. a server's "update now").
  void updateNow() {
    if (stage == UpdateStage.updating) return;
    _runBackground();
  }

  Future<void> _runBackground() async {
    stage = UpdateStage.updating;
    error = null;
    notifyListeners();
    try {
      // Runs to completion while the app keeps running; the rebuilt binaries
      // land on disk as fresh copies without disturbing the live process.
      final proc = await Process.start(_bin('lymnal'), ['update']);
      // Drain the pipes so the child never blocks on a full buffer.
      proc.stdout.listen((_) {});
      proc.stderr.listen((_) {});
      final code = await proc.exitCode;
      if (code == 0) {
        stage = UpdateStage.readyToRefresh;
        _notifyDesktop();
      } else {
        stage = UpdateStage.failed;
        error = 'The update didn\'t finish (exit $code).';
      }
    } catch (e) {
      stage = UpdateStage.failed;
      error = 'Could not run the update: $e';
    }
    notifyListeners();
  }

  /// A best-effort desktop notification, so the "ready to refresh" nudge is seen
  /// even when elyxr isn't the focused window. Silently absent where notify-send
  /// isn't installed.
  Future<void> _notifyDesktop() async {
    try {
      await Process.run('notify-send', [
        '--app-name=elyxr',
        'elyxr updated',
        'A new version is installed. Open elyxr and refresh when you\'re ready.',
      ]);
    } catch (_) {}
  }

  /// Step onto the freshly built version: launch the new binary detached, then
  /// quit this one. Near-instant, since the build already happened.
  Future<void> refreshNow() async {
    if (stage != UpdateStage.readyToRefresh) return;
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
    if (stage == UpdateStage.updating) return;
    _runBackground();
  }
}
