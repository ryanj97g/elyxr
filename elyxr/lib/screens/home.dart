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
import '../state/music.dart';
import '../widgets/deck_slot.dart';
import '../widgets/nostalgia/saver_layer.dart';
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
  // Nostalgia Mode screensaver: after 30s with no interaction, the tube falls to
  // the Matrix rain. Once it's up, only a click dismisses it — moving the mouse
  // doesn't. The timer only runs in Nostalgia Mode; otherwise it's inert.
  static const _idleAfter = Duration(seconds: 30);
  bool _idle = false;
  Timer? _idleTimer;
  // Where the music deck is, so the saver can leave a hole for it. Published by
  // the deck itself (see DeckSlot) because only it knows where it ended up.
  final _deckRect = DeckSlotRect();
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
    _deckRect.dispose();
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
    if (settings.inSettings) {
      tubeChild = const SettingsView();
    } else {
      tubeChild = FilesView(deckRect: _deckRect);
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
      onPointerDown: (e) {
        // The deck is exempt while the saver is up: it's left showing through on
        // purpose, so using it — play, skip, scrub — must not be the thing that
        // dismisses the saver. Everything else still wakes on a click.
        final deck = _deckRect.value;
        if (showSaver && deck != null && deck.contains(e.position)) return;
        _wake();
      },
      onPointerMove: (e) {
        _cursor.value = e.localPosition;
        _activity();
      },
      onPointerHover: (e) {
        _cursor.value = e.localPosition;
        _activity();
      },
      // A scroll has never dismissed the saver (only a pointer down does), so
      // while it's up the wheel is free to do something else: the volume, from
      // anywhere on screen rather than only over the deck. The deck's own wheel
      // handler stands down while the saver is up so a scroll over it isn't
      // counted twice.
      onPointerSignal: (_) => _activity(),
      child: Chassis(
        palette: p,
        nostalgia: settings.nostalgia,
        topRail: TopRail(
          palette: p,
          inSettings: settings.inSettings,
          onToggleSettings: () => settings.inSettings = !settings.inSettings,
          onEasterEgg:
              settings.nostalgia ? () => setState(() => _game = true) : null,
        ),
        tube: Tube(
          palette: p,
          nostalgia: settings.nostalgia,
          // The minigame wins over the screensaver; both live in the overlay.
          overlay: _game
              ? SnakeGame(
                  palette: p,
                  onExit: () => setState(() => _game = false),
                )
              : showSaver
                  ? SaverLayer(
                      palette: p,
                      deckRect: _deckRect,
                      onWake: _wake,
                      onVolume: (d) =>
                          context.read<MusicController>().nudgeVolume(d),
                    )
                  : null,
          child: tubeChild,
        ),
        bottomRail: BottomRail(
          palette: p,
          mode: settings.mode,
          status: session.status,
          onMode: (m) => settings.mode = m,
          inSettings: settings.inSettings,
          nostalgia: settings.nostalgia,
          // Hide the TEXT/GRID rocker while the screensaver lightshow is up — it
          // was the one control left sitting out of place over the saver.
          saver: showSaver,
        ),
      ),
    );

    return PopScope(
      // Android back: leave Settings first rather than closing the app.
      canPop: !settings.inSettings,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && settings.inSettings) settings.inSettings = false;
      },
      child: Stack(
        children: [
          app,
          // Transfer HUD — Nostalgia Mode only.
          if (settings.nostalgia && !settings.inSettings)
            Positioned(
              top: 60,
              left: 14,
              right: 14,
              child: TransferHud(palette: p),
            ),
          // Cursor trail — Nostalgia Mode only.
          if (settings.nostalgia)
            Positioned.fill(
              child: IgnorePointer(
                child: CursorTrail(cursor: _cursor, palette: p),
              ),
            ),
        ],
      ),
    );
  }
}
