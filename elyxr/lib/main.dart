// elyxr — the only part of the system a person touches.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'design/tokens.dart';
import 'state/session.dart';
import 'state/settings.dart';
import 'state/transfers.dart';
import 'util/shake_to_close.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // On Linux the native launcher owns the window's geometry (frameless,
  // chassis-sized, transparent — see linux/runner/my_application.cc). Other
  // platforms have no such launcher, so give window_manager the chassis' own
  // size here; without it the runner opens at its default size with the chassis
  // floating in the middle. window_manager also handles the interactive parts:
  // dragging by the rail and the screw controls.
  await windowManager.ensureInitialized();
  final opts = Platform.isLinux
      ? const WindowOptions(titleBarStyle: TitleBarStyle.hidden)
      : const WindowOptions(
          titleBarStyle: TitleBarStyle.hidden,
          size: Size(kAppWidth, kAppHeight),
          center: true,
        );
  await windowManager.waitUntilReadyToShow(
    opts,
    () async {
      await windowManager.setAsFrameless();
      // The window is a fixed size, so it must never maximize — otherwise a
      // double-click on the rail (e.g. tapping the wordmark) snaps it fullscreen.
      await windowManager.setResizable(false);
      await windowManager.setMaximizable(false);
      await windowManager.show();
      await windowManager.focus();
    },
  );

  final prefs = await SharedPreferences.getInstance();
  final settings = SettingsController(prefs);
  final session = SessionController(prefs, KeyringTokenStore());

  // The queue is written here so it survives a close mid-transfer.
  final support = await _supportDir();
  final transfers = TransferController(
    () => session.client,
    File('${support.path}/queue.json'),
    maxConcurrent: () => settings.atOnce,
  );

  await session.boot();
  await transfers.load();

  // Start the audio engine once, with visualization on so the music player can
  // read the live FFT. Guarded: a headless machine with no audio device just
  // runs silent.
  try {
    await SoLoud.instance.init();
    SoLoud.instance.setVisualizationEnabled(true);
  } catch (e, st) {
    // The audio engine didn't start — the laugh, sound effects, and music would
    // all be silent. Surface it (visible in a terminal run) instead of hiding it,
    // so a "no sound" report has a cause to look at rather than a silent no-op.
    stderr.writeln('elyxr: audio engine failed to start — playback will be silent: $e');
    stderr.writeln(st.toString());
  }

  runApp(ShakeToClose(
    child: ElyxrApp(
      settings: settings,
      session: session,
      transfers: transfers,
    ),
  ));
}

Future<Directory> _supportDir() async {
  try {
    return await getApplicationSupportDirectory();
  } catch (_) {
    // Headless / test fallback.
    final d = Directory('${Directory.systemTemp.path}/elyxr');
    await d.create(recursive: true);
    return d;
  }
}
