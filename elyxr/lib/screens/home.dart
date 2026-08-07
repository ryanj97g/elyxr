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
import '../widgets/nostalgia/mini_music_bar.dart';
import '../widgets/nostalgia/snake_game.dart';
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

  // Nostalgia Mode screensaver: after 30s with no interaction, the tube falls to
  // the Matrix rain. Once it's up, only a click dismisses it — moving the mouse
  // doesn't. The timer only runs in Nostalgia Mode; otherwise it's inert.
  static const _idleAfter = Duration(seconds: 30);
  bool _idle = false;
  Timer? _idleTimer;
  // The hidden Snake minigame (wordmark ×7 in Nostalgia Mode).
  bool _game = false;

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

  // A click wakes the screensaver and restarts the idle countdown.
  void _wake() {
    if (_idle) setState(() => _idle = false);
    _armIdle();
  }

  // Movement/scroll restarts the countdown while the app is in use, but does not
  // dismiss the screensaver once it's up — only a click does that.
  void _activity() {
    if (!_idle) _armIdle();
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

    final app = Listener(
      // A click wakes the screensaver; movement only resets the idle countdown
      // and feeds the cursor trail. An ancestor of the whole tree, so it sees
      // the event even when the screensaver overlay absorbs the waking click.
      onPointerDown: (_) => _wake(),
      onPointerMove: (e) {
        _cursor.value = e.localPosition;
        _activity();
      },
      onPointerHover: (e) {
        _cursor.value = e.localPosition;
        _activity();
      },
      onPointerSignal: (_) => _activity(),
      child: Chassis(
        palette: p,
        topRail: TopRail(
          palette: p,
          inSettings: _inSettings,
          onToggleSettings: () => setState(() => _inSettings = !_inSettings),
          onEasterEgg:
              settings.nostalgia ? () => setState(() => _game = true) : null,
        ),
        tube: Tube(
          palette: p,
          // The minigame wins over the screensaver; both live in the overlay.
          overlay: _game
              ? SnakeGame(
                  palette: p,
                  onExit: () => setState(() => _game = false),
                )
              : showSaver
                  ? GestureDetector(
                      // A click dismisses the screensaver and is absorbed here so
                      // it doesn't also click a file underneath.
                      behavior: HitTestBehavior.opaque,
                      onTap: _wake,
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
          nostalgia: settings.nostalgia,
        ),
      ),
    );

    return Stack(
      children: [
        app,
        // Transfer HUD — Nostalgia Mode only.
        if (settings.nostalgia && !_inSettings)
          Positioned(
            top: 60,
            left: 14,
            right: 14,
            child: TransferHud(palette: p),
          ),
        // The mini music bar rides at the bottom of the tube whenever a track is
        // active — any mode, since streaming a trove file isn't a nostalgia-only
        // feature. It self-hides when nothing's playing.
        if (!_inSettings)
          Positioned(
            left: 14,
            right: 14,
            bottom: 62,
            child: MiniMusicBar(palette: p),
          ),
        // Cursor trail — Nostalgia Mode only.
        if (settings.nostalgia)
          Positioned.fill(
            child: IgnorePointer(
              child: CursorTrail(cursor: _cursor, palette: p),
            ),
          ),
      ],
    );
  }
}
