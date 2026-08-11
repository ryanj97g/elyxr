// elyxr — the only part of the system a person touches.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'design/tokens.dart';
import 'state/session.dart';
import 'state/settings.dart';
import 'state/transfers.dart';
import 'util/open_external.dart';
import 'util/platform_caps.dart';
import 'util/shake_to_close.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  // On a phone the chassis IS the device — go true fullscreen so it isn't boxed
  // in by the status bar up top and the navigation bar at the bottom. Sticky:
  // a swipe from an edge reveals the bars briefly, then they slide away again.
  if (Caps.isMobile) {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  // Desktop only: give the app a managed window. On Linux the native launcher
  // owns the window's geometry (frameless, chassis-sized, transparent — see
  // linux/runner/my_application.cc); Windows/macOS have no such launcher, so
  // window_manager sizes the window to the chassis here. window_manager also
  // handles the interactive parts: dragging by the rail and the screw controls.
  // A phone has no window to manage — the app is simply full-screen — so this is
  // skipped there (calling it would throw at startup).
  if (Caps.hasWindowManager) {
    await windowManager.ensureInitialized();
    // Linux's native runner owns a transparent window sized to include the glow
    // ring. Windows windows are opaque, so the ring would paint as a black
    // border — instead size the window to the chassis exactly (no ring) and let
    // the chassis fill it, so there's no black margin.
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
  }

  // Register any dev-dropped fonts (assets/fonts/custom/) before settings apply
  // the saved terminal face — otherwise a saved custom face wouldn't exist yet.
  await loadCustomFonts();

  final prefs = await SharedPreferences.getInstance();
  final settings = SettingsController(prefs);
  // A phone can't write ~/Downloads; give it a real app-writable folder the
  // first time (a path the user sets later is respected).
  if (Caps.isMobile && settings.downloadDir == '~/Downloads') {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dl = Directory('${docs.path}/downloads');
      await dl.create(recursive: true);
      settings.downloadDir = dl.path;
    } catch (_) {}
  }
  final session = SessionController(prefs, KeyringTokenStore());

  // The queue is written here so it survives a close mid-transfer.
  final support = await _supportDir();
  final transfers = TransferController(
    () => session.client,
    File('${support.path}/queue.json'),
    maxConcurrent: () => settings.atOnce,
  );

  // Reclaim any working copies a previous run left in the temp folder (opened
  // files whose cleanup didn't get to run — a crash or force-quit). Fire and
  // forget; it never blocks startup.
  OpenExternal.sweepStale();

  // Music needs no init beyond MediaKit.ensureInitialized() above (it builds its
  // player on demand); the Nostalgia sound effects create a one-shot player per
  // clip, so there's nothing else to start up here.

  // DRAW FIRST, then connect. boot() talks to the network, and it used to be
  // awaited right here — so on a machine that couldn't reach its server (a
  // firewall blocking the connection, a tailnet that's down) the window simply
  // never appeared and the app looked dead. Nothing about the first frame needs
  // the link: the session starts at LinkStatus.connecting and the UI already
  // draws every outcome, including none.
  runApp(ShakeToClose(
    child: ElyxrApp(
      settings: settings,
      session: session,
      transfers: transfers,
    ),
  ));

  // Unawaited on purpose. Both report themselves through their controllers, so
  // the UI follows along as they finish; neither can hold up the window.
  session.boot();
  transfers.load();
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
