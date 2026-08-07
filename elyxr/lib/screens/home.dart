// The connected app: the chassis with its rails, swapping the tube between the
// files view and the settings screen. Holding the wordmark toggles the two
// (§ DESIGN Interactions); nothing else marks that path.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../design/chassis.dart';
import '../design/tokens.dart';
import '../state/session.dart';
import '../state/settings.dart';
import '../widgets/nostalgia/cursor_trail.dart';
import '../widgets/nostalgia/matrix_rain.dart';
import '../widgets/nostalgia/transfer_hud.dart';
import '../widgets/rails.dart';
import 'files_view.dart';
import 'settings_view.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _inSettings = false;

  // Nostalgia Mode screensaver: after ~2 minutes with no interaction, the tube
  // falls to the Matrix rain. Any pointer input wakes it. The timer only runs in
  // Nostalgia Mode; otherwise it's inert.
  static const _idleAfter = Duration(seconds: 120);
  bool _idle = false;
  Timer? _idleTimer;

  // The live pointer position, fed to the cursor trail (Nostalgia Mode).
  final ValueNotifier<Offset?> _cursor = ValueNotifier(null);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _armIdle());
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _cursor.dispose();
    super.dispose();
  }

  void _armIdle() {
    _idleTimer?.cancel();
    if (!mounted) return;
    if (context.read<SettingsController>().nostalgia) {
      _idleTimer = Timer(_idleAfter, () {
        if (mounted) setState(() => _idle = true);
      });
    }
  }

  // Any interaction wakes the screen and restarts the idle countdown.
  void _bump() {
    if (_idle) setState(() => _idle = false);
    _armIdle();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>();
    final session = context.watch<SessionController>();
    final p = settings.palette;
    final showSaver = settings.nostalgia && _idle;

    // The trove is the main view on every device now — a client browses it over
    // the network, a server reads it straight off local disk. The server's own
    // controls (pairing, limits) live in Settings.
    Widget tubeChild;
    if (_inSettings) {
      tubeChild = const SettingsView();
    } else {
      tubeChild = const FilesView();
    }

    // Density is a global text scale for everything on the glass — the whole
    // terminal grows or tightens together. The metal rails sit outside this
    // MediaQuery, so the physical controls keep their fixed size.
    tubeChild = MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(settings.density.scale)),
      child: tubeChild,
    );

    // Nostalgia Mode turns the pointer into a crosshair over the file browser.
    if (settings.nostalgia && !_inSettings) {
      tubeChild = MouseRegion(cursor: SystemMouseCursors.precise, child: tubeChild);
    }

    final app = Listener(
      // Wakes the screensaver, resets the idle countdown, and feeds the cursor
      // trail. An ancestor of the whole tree, so it sees the event even when the
      // screensaver overlay absorbs the tap that dismisses it.
      onPointerDown: (_) => _bump(),
      onPointerMove: (e) {
        _cursor.value = e.localPosition;
        _bump();
      },
      onPointerHover: (e) {
        _cursor.value = e.localPosition;
        _bump();
      },
      onPointerSignal: (_) => _bump(),
      child: Chassis(
        palette: p,
        topRail: TopRail(
          palette: p,
          inSettings: _inSettings,
          onToggleSettings: () => setState(() => _inSettings = !_inSettings),
        ),
        tube: Tube(
          palette: p,
          overlay: showSaver
              ? GestureDetector(
                  // Absorb the waking tap so it doesn't also click a file; the
                  // ancestor Listener still registers it and dismisses the saver.
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  child: MatrixRain(palette: p),
                )
              : null,
          child: tubeChild,
        ),
        bottomRail: BottomRail(
          palette: p,
          mode: settings.mode,
          status: session.status,
          onMode: (m) => settings.mode = m,
          inSettings: _inSettings,
        ),
      ),
    );

    if (!settings.nostalgia) return app;
    // Nostalgia overlays: the transfer HUD near the top of the tube, and the
    // cursor trail floating over everything (non-interactive).
    return Stack(
      children: [
        app,
        if (!_inSettings)
          Positioned(
            top: 60,
            left: 14,
            right: 14,
            child: TransferHud(palette: p),
          ),
        Positioned.fill(
          child: IgnorePointer(
            child: CursorTrail(cursor: _cursor, palette: p),
          ),
        ),
      ],
    );
  }
}
