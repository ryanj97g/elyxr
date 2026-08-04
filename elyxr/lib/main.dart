// Elyxr — the only part of the system a person touches.

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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The metal chassis IS the window: frameless, transparent-cornered, sized
  // exactly to the device, not resizable (DESIGN.md — fixed 440×884).
  await windowManager.ensureInitialized();
  const chassis = Size(kAppWidth, kAppHeight);
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: chassis,
      minimumSize: chassis,
      maximumSize: chassis,
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.hidden,
      title: 'Elyxr',
    ),
    () async {
      await windowManager.setAsFrameless();
      await windowManager.setResizable(false);
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

  runApp(ElyxrApp(
    settings: settings,
    session: session,
    transfers: transfers,
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
