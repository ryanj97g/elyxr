// Runs the optional folder mount: launches the `gate` program with the server
// address, the bearer token, and where to mount, then stops it on request. gate
// itself is the filesystem window (it rides the local lymnal proxy's limbo);
// this just starts and stops it, reflects whether it's running, and clears the
// mount point away afterwards so no phantom folder is left behind.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

class TroveMountController extends ChangeNotifier {
  Process? _proc;
  bool _starting = false;
  String? _error;

  bool get mounted => _proc != null;
  String? get error => _error;

  String _gateBin() {
    // The mount program is now 'gate' (a thin FUSE window). Installed in the
    // user's own bin; fall back to PATH.
    final home = Platform.environment['HOME'];
    for (final path in [
      if (home != null) '$home/.local/bin/gate',
    ]) {
      if (File(path).existsSync()) return path;
    }
    return 'gate';
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
        _gateBin(),
        const [],
        environment: {
          // The gate talks to the *local* lymnal proxy, not the remote — so it
          // rides limbo (cached reads, queued writes) like the app does. The
          // proxy injects the real token; the gate's own is unused.
          'ELYXR_SERVER': '127.0.0.1:7749',
          'ELYXR_TOKEN': token,
          'ELYXR_MOUNT': mountPath,
        },
      );
      _proc = proc;
      // Give the mounted folder the trove's own icon, so it reads as the trove
      // in the file manager and sidebar rather than a generic folder.
      _stampFolderIcon(mountPath);
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

  /// Point the file manager at the trove icon for this folder. Best-effort:
  /// GNOME/Nautilus and other GVFS file managers read metadata::custom-icon;
  /// where `gio` isn't present it simply stays a normal folder.
  Future<void> _stampFolderIcon(String mountPath) async {
    try {
      final home = Platform.environment['HOME'];
      if (home == null) return;
      final iconPath = '$home/.cache/elyxr/trove.png';
      final iconFile = File(iconPath);
      // Always (re)write it, so a branding change refreshes the cached copy
      // instead of leaving an old icon behind.
      await iconFile.parent.create(recursive: true);
      final bytes = await rootBundle.load('assets/branding/trove.png');
      await iconFile.writeAsBytes(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
          flush: true);
      await Process.run('gio', ['set', mountPath, 'metadata::custom-icon', 'file://$iconPath']);
    } catch (_) {
      // Cosmetic only — never let it affect the mount.
    }
  }

  /// Stop the mount, then clear the mount point away so no phantom folder is
  /// left on the Desktop. Safe to call when nothing is running.
  Future<void> unmount({required String mountPath}) async {
    final p = _proc;
    _proc = null;
    notifyListeners();
    if (p != null) p.kill(ProcessSignal.sigterm);
    await _removeMountPoint(mountPath);
  }

  /// Remove a mount point left over from a previous run: clear its custom icon
  /// and delete the folder. Only touches a folder this app owns and never one
  /// with real files in it — the non-recursive delete refuses a non-empty
  /// folder or a live mount. No-op while we're mounting here.
  Future<void> cleanupStaleMount({required String mountPath}) async {
    if (_proc != null) return;
    if (!Directory(mountPath).existsSync()) return;
    await _removeMountPoint(mountPath);
  }

  /// The shared teardown: unmount anything still mounted here (including a dead
  /// mount a crashed gate left behind), drop the folder's custom icon, then
  /// remove the folder if it's empty. Every step is best-effort.
  Future<void> _removeMountPoint(String mountPath) async {
    try {
      await Process.run('fusermount3', ['-u', mountPath]);
    } catch (_) {}
    try {
      await Process.run('gio', ['set', '-t', 'unset', mountPath, 'metadata::custom-icon']);
    } catch (_) {}
    try {
      // Non-recursive: throws on a non-empty folder (real user files) or a busy
      // mount, so it only ever removes an empty leftover point.
      await Directory(mountPath).delete();
    } catch (_) {}
  }
}
