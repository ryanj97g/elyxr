// Runs the trove mount: launches the `trove` program with the server address,
// the bearer token, and where to mount, then stops it on request. trove itself
// is the filesystem (on-demand reads, write-back, cache); this just starts and
// stops it and reflects whether it's running.

import 'dart:io';

import 'package:flutter/foundation.dart';

class TroveMountController extends ChangeNotifier {
  Process? _proc;
  bool _starting = false;
  String? _error;

  bool get mounted => _proc != null;
  String? get error => _error;

  String _troveBin() {
    // The installer now puts binaries in ~/.local/bin (no root, password-free
    // updates); fall back to the old system-wide spot, then to PATH.
    final home = Platform.environment['HOME'];
    for (final path in [
      if (home != null) '$home/.local/bin/trove',
      '/usr/local/bin/trove',
    ]) {
      if (File(path).existsSync()) return path;
    }
    return 'trove';
  }

  /// Start the mount. No-op if it's already running or starting.
  Future<void> mount({
    required String serverAddress,
    required String token,
    required String mountPath,
  }) async {
    if (_proc != null || _starting) return;
    if (!Platform.isLinux) {
      _error = 'The folder mount is Linux-only for now.';
      notifyListeners();
      return;
    }
    _starting = true;
    _error = null;
    notifyListeners();
    try {
      final dir = Directory(mountPath);
      if (!await dir.exists()) await dir.create(recursive: true);
      // Clear any stale mount left behind by a previous run.
      try {
        await Process.run('fusermount3', ['-u', mountPath]);
      } catch (_) {}
      final proc = await Process.start(
        _troveBin(),
        const [],
        environment: {
          'ELYXR_SERVER': serverAddress,
          'ELYXR_TOKEN': token,
          'ELYXR_MOUNT': mountPath,
        },
      );
      _proc = proc;
      // If trove exits on its own (bad mount, lost server), reflect it.
      proc.exitCode.then((code) {
        if (identical(_proc, proc)) {
          _proc = null;
          if (code != 0) _error = 'The mount stopped (exit $code).';
          notifyListeners();
        }
      });
    } catch (e) {
      _error = 'Could not start the mount: $e';
      _proc = null;
    }
    _starting = false;
    notifyListeners();
  }

  /// Stop the mount. Safe to call when nothing is running.
  Future<void> unmount({required String mountPath}) async {
    final p = _proc;
    _proc = null;
    notifyListeners();
    if (p != null) p.kill(ProcessSignal.sigterm);
    // trove auto-unmounts when it exits, but make sure the point is clear.
    try {
      await Process.run('fusermount3', ['-u', mountPath]);
    } catch (_) {}
  }
}
