// Runs `lymnal update` from inside the app — the one command that pulls the
// latest, rebuilds what changed, reinstalls, and restarts the service. It's the
// same on a server ("Update now") and a client ("Update available"): each
// device updates itself from the repository, never from another device. Updates
// are password-free (binaries live in ~/.local/bin, lymnal is a user service),
// so this needs no privilege prompt.
//
// The update rebuilds the app too, and you can't overwrite a running program's
// own binary — that fails mid-build with "Text file busy". So the app doesn't
// try to update itself in place. It launches a *separate*, detached process
// that runs the update and then reopens the app, and then quits. The app closes,
// the update runs unobstructed, and a fresh copy opens when it's done — the
// clean restart the design calls for.

import 'dart:io';

import 'package:flutter/foundation.dart';

class UpdateController extends ChangeNotifier {
  String? error;

  String _lymnalBin() {
    final home = Platform.environment['HOME'];
    for (final path in [
      if (home != null) '$home/.local/bin/lymnal',
      '/usr/local/bin/lymnal',
    ]) {
      if (File(path).existsSync()) return path;
    }
    return 'lymnal';
  }

  /// Spawn the detached updater and quit. The detached shell runs the update,
  /// then reopens this app. If spawning fails we surface it and stay open.
  Future<void> startAndRestart() async {
    final lymnal = _lymnalBin();
    final app = Platform.resolvedExecutable;
    // Reopen regardless of the update's exit so the person is never left with no
    // window; a successful update reopens the fresh build, a failed one reopens
    // what was already there.
    final cmd = "'$lymnal' update; exec '$app'";
    try {
      await Process.start(
        'bash',
        ['-lc', cmd],
        mode: ProcessStartMode.detached,
        runInShell: false,
      );
    } catch (e) {
      error = 'Could not start the update: $e';
      notifyListeners();
      return;
    }
    // Give the detached process a moment to take hold, then release this one so
    // its binary is free to be rebuilt.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    exit(0);
  }
}
