// elyxr — the only part of the system a person touches.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'design/tokens.dart';
import 'state/session.dart';
import 'state/settings.dart';
import 'state/transfers.dart';
import 'util/open_external.dart';
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
          size: Size(kWindowWidth, kWindowHeight),
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

  // Reclaim any working copies a previous run left in the temp folder (opened
  // files whose cleanup didn't get to run — a crash or force-quit). Fire and
  // forget; it never blocks startup.
  OpenExternal.sweepStale();

  // No global audio init needed — audioplayers creates players on demand and
  // uses the system's GStreamer, so there's nothing to start up here.

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
