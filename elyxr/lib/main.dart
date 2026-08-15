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
    // Every step here is best-effort, and showing the window is the ONLY one that
    // matters. It used to be the fifth await in a row inside the callback below,
    // so if any earlier one threw or stalled — and on Windows they can — show()
    // never ran: the process started, took a taskbar slot, and never put anything
    // on screen. Which is indistinguishable, to anyone using it, from the app
    // being broken.
    //
    // So: one guarded call before showing, then show, then the cosmetic settings
    // afterwards where they can't cost us a window. The whole block is timed out
    // as well, because a hang here would stop runApp being reached at all.
    Future<void> attempt(Future<void> Function() step) async {
      try {
        await step();
      } catch (_) {}
    }

    try {
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
      await windowManager
          .waitUntilReadyToShow(opts, () async {
            // Before showing, so there's no flash of a title bar.
            await attempt(windowManager.setAsFrameless);
            await attempt(windowManager.show);
            await attempt(windowManager.focus);
            // After showing: the window is a fixed size and must never maximize
            // (a double-click on the rail would otherwise snap it fullscreen), but
            // neither of these is worth a hidden window if they misbehave.
            await attempt(() => windowManager.setResizable(false));
            await attempt(() => windowManager.setMaximizable(false));
          })
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      // Window management failed or hung. Ask once more for a visible window and
      // carry on regardless — an app with an ugly frame still works.
      await attempt(windowManager.show);
    }
  }

  // Region gate: the app refuses to run only when the device is set to the
  // blocked region — read from its own locale, nothing over the network. Anything
  // else runs. Silent by design: a blocked device just gets a dead screen.
  if (_regionBlocked()) {
    runApp(const _Blocked());
    return;
  }

  try {
    await _start();
  } catch (e) {
    runApp(_StartupFailure('$e'));
  }
}

const _blockedCountries = {'IL'};

/// True only when the device is *certainly* set to a blocked region — read from
/// the system locale's country code (e.g. "he_IL" -> "IL"), nothing over the
/// network. Blocks only on a positive match; any other country, or a locale with
/// no country at all, runs.
bool _regionBlocked() {
  final match = RegExp(r'[_-]([A-Za-z]{2})').firstMatch(Platform.localeName);
  final country = match?.group(1)?.toUpperCase();
  return country != null && _blockedCountries.contains(country);
}

/// The dead screen shown when the region gate blocks: no branding, no message —
/// it just doesn't work.
class _Blocked extends StatelessWidget {
  const _Blocked();

  @override
  Widget build(BuildContext context) => const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: ColoredBox(color: Color(0xFF000000)),
      );
}

Future<void> _start() async {
  // Register any dev-dropped fonts (assets/fonts/custom/) before settings apply
  // the saved terminal face — otherwise a saved custom face wouldn't exist yet.
  await loadCustomFonts();

  final prefs = await _openPrefs();
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

Future<SharedPreferences> _openPrefs() async {
  try {
    return await SharedPreferences.getInstance();
  } catch (_) {
    await _setAsidePrefsFile();
    return SharedPreferences.getInstance();
  }
}

Future<void> _setAsidePrefsFile() async {
  try {
    final dir = await getApplicationSupportDirectory();
    final sep = Platform.pathSeparator;
    final f = File('${dir.path}${sep}shared_preferences.json');
    if (!await f.exists()) return;
    final kept = File('${f.path}.unreadable');
    if (await kept.exists()) await kept.delete();
    await f.rename(kept.path);
  } catch (_) {
  }
}

class _StartupFailure extends StatelessWidget {
  final String message;
  const _StartupFailure(this.message);

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: ColoredBox(
          color: const Color(0xFF0B0F0C),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('ELYXR COULDN\'T START',
                      style: TextStyle(
                          color: Color(0xFF2BE05E),
                          fontSize: 20,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 14),
                  Flexible(
                    child: SingleChildScrollView(
                      child: SelectableText(message,
                          style: const TextStyle(
                              color: Color(0xFF9BB3A2), fontSize: 13)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
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
