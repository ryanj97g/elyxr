// The app root: provides the controllers, centres the fixed 440×884 chassis on
// the dark desk, and chooses between first run and the connected home from the
// session's link status.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'api/admin_client.dart';
import 'design/tokens.dart';
import 'api/lymnal_client.dart';
import 'state/actions.dart';
import 'state/browse.dart';
import 'state/music.dart';
import 'state/server.dart';
import 'state/session.dart';
import 'state/settings.dart';
import 'state/sound.dart';
import 'state/transfers.dart';
import 'state/trove_mount.dart';
import 'state/updater.dart';
import 'util/drag_out.dart';
import 'util/paths.dart';
import 'util/shake_to_tailscale.dart';
import 'util/platform_caps.dart';
import 'screens/first_run.dart';
import 'screens/home.dart';

class ElyxrApp extends StatelessWidget {
  final SettingsController settings;
  final SessionController session;
  final TransferController transfers;

  const ElyxrApp({
    super.key,
    required this.settings,
    required this.session,
    required this.transfers,
  });

  @override
  Widget build(BuildContext context) {
    final browse = BrowseController(session);
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: session),
        ChangeNotifierProvider.value(value: transfers),
        ChangeNotifierProvider.value(value: browse),
        ChangeNotifierProvider(create: (_) => ServerController()),
        ChangeNotifierProvider(create: (_) => TroveMountController()),
        ChangeNotifierProvider(create: (_) => UpdateController()),
        Provider.value(value: FileActions(browse, transfers, settings)),
        Provider(create: (_) => SoundController(settings)),
        ChangeNotifierProvider(create: (_) => MusicController()),
      ],
      child: ShakeToTailscale(
        child: MaterialApp(
          title: 'elyxr',
          debugShowCheckedModeBanner: false,
          color: Colors.transparent,
          theme: ThemeData(
            useMaterial3: true,
            fontFamily: 'VT323',
            scaffoldBackgroundColor: Colors.transparent,
          ),
          home: const _Root(),
        ),
      ),
    );
  }
}

class _Root extends StatefulWidget {
  const _Root();

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  static Widget _pinned(Widget child) => Center(
        child: FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            key: const ValueKey('elyxr-chassis'),
            width: kAppWidth,
            height: kAppHeight,
            child: child,
          ),
        ),
      );

  bool _openedOnce = false;
  bool _serverTried = false;
  bool _troveCleaned = false;
  LymnalClient? _dragClient;
  LinkStatus? _prevStatus;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final settings = context.watch<SettingsController>();
    final browse = context.read<BrowseController>();
    final server = context.read<ServerController>();

    // A retro chirp when the link comes up (Nostalgia Mode). Fires on the
    // transition into `ok`, once.
    if (_prevStatus != LinkStatus.ok && session.status == LinkStatus.ok) {
      final sound = context.read<SoundController>();
      WidgetsBinding.instance.addPostFrameCallback((_) => sound.connected());
    }
    _prevStatus = session.status;

    // Keep the drag-out helper pointed at the live connection, so a file pulled
    // out of the window can be fetched and written to wherever it's dropped.
    if (_dragClient != session.client) {
      _dragClient = session.client;
      DragOut.useClient(session.client);
    }

    // Server mode connects to the local lymnal admin surface with the
    // machine-local admin token.
    if (settings.appMode == AppMode.server && !_serverTried) {
      _serverTried = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final dir = expandTilde('~/.local/share/lymnal');
        final token = await AdminClient.readToken(dir);
        final addr = await AdminClient.readAddress(dir) ?? session.serverAddress;
        if (token != null && addr != null) {
          server.connect(AdminClient(baseUrl: 'http://$addr', adminToken: token));
        }
        // Browse the trove straight off local disk in server mode — the files
        // are on this machine, so no token and no round-trip.
        final trovePath = await AdminClient.readTrovePath(dir);
        if (trovePath != null) {
          session.useLocalTrove(trovePath);
          browse.open('');
          browse.connectEvents();
        }
      });
    }
    if (settings.appMode == AppMode.client && _serverTried) {
      _serverTried = false;
      server.connect(null);
      session.useRemote();
    }

    // The trove mount (client only): the folder is live while the TROVE switch
    // is on and the link is up. trove is what actually mounts it; this starts
    // and stops that.
    final mount = context.read<TroveMountController>();
    final wantMount = settings.appMode == AppMode.client &&
        settings.trove &&
        session.status == LinkStatus.ok;
    if (wantMount && !mount.mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final token = session.bearerToken;
        final addr = session.serverAddress;
        if (token != null && addr != null) {
          await mount.mount(
            serverAddress: addr,
            token: token,
            mountPath: expandTilde(settings.mountPath),
          );
        }
      });
    } else if (!wantMount && mount.mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        mount.unmount(mountPath: expandTilde(settings.mountPath));
      });
    } else if (settings.appMode == AppMode.client &&
        !wantMount &&
        !mount.mounted &&
        !_troveCleaned) {
      // A folder left over from a previous session (or an old build) hangs
      // around because nothing is mounted to unmount. Clear it once at startup
      // when the gate is off, so no phantom trove folder lingers on the Desktop.
      // Client only: on the server this same path is the real trove.
      _troveCleaned = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        mount.cleanupStaleMount(mountPath: expandTilde(settings.mountPath));
      });
    }

    // When a token is present and the link is up, open the trove once and start
    // listening for live changes.
    if (!session.isFirstRun && session.status == LinkStatus.ok && !_openedOnce) {
      _openedOnce = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        browse.open('');
        browse.connectEvents();
      });
    }
    if (session.isFirstRun) _openedOnce = false;

    // In server mode this device manages its own lymnal (no client pairing
    // needed), so it goes straight to the connected home. Otherwise, no token
    // yet means first run.
    final child = settings.appMode == AppMode.server
        ? const HomeScreen()
        : (session.isFirstRun ? const FirstRunScreen() : const HomeScreen());

    final p = settings.palette;
    final g = p.edgeGlow;

    if (Caps.isMobile) {
      return Scaffold(
        backgroundColor: Colors.black,
        resizeToAvoidBottomInset: false,
        body: _pinned(child),
      );
    }

    if (!Platform.isLinux) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: _pinned(child),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            width: kWindowWidth,
            height: kWindowHeight,
            child: Center(
              // All three layers are ALWAYS present so the Stack's child count
              // never changes — otherwise the app (layer 2) shifts position when
              // the glow appears/disappears, and Flutter, matching children by
              // position, would tear down and rebuild the whole app, dropping its
              // state (closing Settings, killing an in-progress drag). Only the
              // glow *shadow* is gated on the drag amount; the layers stay put,
              // and the chassis carries a key so its identity is rock-stable.
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  // 1) The glow that LEAVES the chassis: a bloom that bleeds
                  //    outward into the transparent ring and fades to nothing
                  //    (no hard edge — it dissolves inside the room).
                  SizedBox(
                    width: kAppWidth,
                    height: kAppHeight,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(9),
                        boxShadow: g > 0.001
                            ? [
                                BoxShadow(
                                  color: p.a.withValues(
                                      alpha: (0.55 * g).clamp(0.0, 1.0)),
                                  blurRadius: 14 + 26 * g,
                                  spreadRadius: 1 + 8 * g,
                                ),
                                BoxShadow(
                                  color: p.a.withValues(
                                      alpha: (0.26 * g).clamp(0.0, 1.0)),
                                  blurRadius: 30 + 44 * g,
                                  spreadRadius: 1 + 4 * g,
                                ),
                              ]
                            : null,
                      ),
                    ),
                  ),
                  // 2) The chassis itself, at full size — keyed so it keeps its
                  //    identity (and its state) no matter what siblings do.
                  SizedBox(
                    key: const ValueKey('elyxr-chassis'),
                    width: kAppWidth,
                    height: kAppHeight,
                    child: child,
                  ),
                  // 3) The glow OVER the chassis: brought to front, an inner
                  //    bloom that spills forward across the metal edge and fades
                  //    inward — a lit tube glowing over its own bezel, not a
                  //    housing that's merely backlit.
                  IgnorePointer(
                    child: SizedBox(
                      width: kAppWidth,
                      height: kAppHeight,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(9),
                          boxShadow: g > 0.001
                              ? [
                                  BoxShadow(
                                    color: p.a.withValues(
                                        alpha: (0.45 * g).clamp(0.0, 1.0)),
                                    blurRadius: 18 + 26 * g,
                                    spreadRadius: 0,
                                    blurStyle: BlurStyle.inner,
                                  ),
                                ]
                              : null,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
