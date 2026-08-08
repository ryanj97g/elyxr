// The physical controls on the metal: the top rail with the wordmark (hold it
// to reach settings), and the bottom rail with the TEXT/GRID rocker, the TROVE
// switch, and the status LED. "Everything on the metal is a physical control."

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../design/text.dart';
import '../design/tokens.dart';
import '../state/session.dart';
import '../state/settings.dart';
import 'nostalgia/nonsense_button.dart';

/// The top rail: screw · ELYXR · hold-bar · vent · v0.9 · screw.
///
/// Holding the wordmark for 250ms is the only way into settings. Nothing marks
/// it as pressable, and nothing should (DESIGN.md · Interactions).
class TopRail extends StatefulWidget {
  final Palette palette;
  final bool inSettings;
  final VoidCallback onToggleSettings;
  /// Tapping the wordmark seven times quickly fires this (the hidden minigame,
  /// in Nostalgia Mode). Null disables it — a hold still opens settings.
  final VoidCallback? onEasterEgg;

  const TopRail({
    super.key,
    required this.palette,
    required this.inSettings,
    required this.onToggleSettings,
    this.onEasterEgg,
  });

  @override
  State<TopRail> createState() => _TopRailState();
}

class _TopRailState extends State<TopRail> {
  bool _holding = false;
  Timer? _timer;
  // A quick-tap counter, distinct from the hold — seven in a row is the egg.
  int _taps = 0;
  Timer? _tapReset;

  void _press() {
    setState(() => _holding = true);
    _timer = Timer(const Duration(milliseconds: 250), () {
      widget.onToggleSettings();
      if (mounted) setState(() => _holding = false);
    });
  }

  void _release() {
    _timer?.cancel();
    if (mounted) setState(() => _holding = false);
  }

  void _tap() {
    if (widget.onEasterEgg == null) return;
    _tapReset?.cancel();
    _taps++;
    _tapReset = Timer(const Duration(milliseconds: 700), () => _taps = 0);
    if (_taps >= 7) {
      _taps = 0;
      _tapReset?.cancel();
      widget.onEasterEgg!.call();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _tapReset?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final lit = widget.inSettings || _holding;
    return Padding(
      padding: const EdgeInsets.fromLTRB(3, 1, 3, 0),
      child: Row(
        children: [
          // Left screw quietly minimizes the window.
          _screw(p, onTap: () => windowManager.minimize(), tip: 'Minimize'),
          const SizedBox(width: 9),
          GestureDetector(
            onTapDown: (_) => _press(),
            onTapUp: (_) => _release(),
            onTapCancel: _release,
            onTap: _tap,
            behavior: HitTestBehavior.opaque,
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 200),
              style: TextStyle(
                fontFamily: Fonts.chassis,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                letterSpacing: lit ? 15 * 0.24 : 15 * 0.4,
                color: lit ? p.a : p.ml,
                shadows: lit
                    ? [Shadow(color: p.a, blurRadius: 11)]
                    : const [Shadow(color: Color(0xFF0C0D0F), offset: Offset(0, 1))],
              ),
              child: const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Text('ELYXR'),
              ),
            ),
          ),
          const SizedBox(width: 9),
          // Hold progress bar, only visible while holding.
          AnimatedOpacity(
            opacity: _holding ? 1 : 0,
            duration: const Duration(milliseconds: 150),
            child: Container(
              width: 26,
              height: 3,
              decoration: BoxDecoration(
                color: p.mv1,
                borderRadius: BorderRadius.circular(2),
              ),
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: _holding ? 1 : 0),
                duration: Duration(milliseconds: _holding ? 250 : 0),
                builder: (context, v, _) => FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: v,
                  child: Container(
                    decoration: BoxDecoration(
                      color: p.a,
                      boxShadow: [BoxShadow(color: p.a, blurRadius: 6)],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 9),
          // Vent.
          Expanded(
            child: Container(
              height: 6,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(3),
                gradient: LinearGradient(
                  colors: [p.mv1, p.mv2],
                  tileMode: TileMode.repeated,
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  stops: const [0.4, 0.6],
                ),
              ),
            ),
          ),
          const SizedBox(width: 9),
          // The version sits on the metal, so it uses the fixed chassis face —
          // it stays put when the terminal (screen) face is swapped.
          Text('v0.9', style: chassis(9, p.mt)),
          const SizedBox(width: 9),
          // Right screw quietly closes the window.
          _screw(p, onTap: () => windowManager.close(), tip: 'Close'),
        ],
      ),
    );
  }

  /// A chassis screw. Identical in look everywhere; when given [onTap] it also
  /// acts as a window control (a click cursor and tooltip, same size and colour).
  Widget _screw(Palette p, {VoidCallback? onTap, String? tip}) {
    final dot = Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          center: const Alignment(-0.3, -0.3),
          colors: [p.mt, const Color(0xFF212823)],
        ),
      ),
    );
    if (onTap == null) return dot;
    // The visible screw stays 8px, but the tap target around it is much larger
    // so it's easy to hit without aiming at the tiny circle.
    Widget w = GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 26,
        height: 20,
        alignment: Alignment.center,
        color: Colors.transparent,
        child: dot,
      ),
    );
    w = MouseRegion(cursor: SystemMouseCursors.click, child: w);
    if (tip != null) w = Tooltip(message: tip, child: w);
    return w;
  }
}

/// The bottom rail: TEXT/GRID rocker · status LED. (The optional file-browser
/// mount toggle now lives in Settings, since it's off by default.)
class BottomRail extends StatelessWidget {
  final Palette palette;
  final ViewMode mode;
  final LinkStatus status;
  final ValueChanged<ViewMode> onMode;
  // The TEXT/GRID rocker only controls the file list, so it's hidden while the
  // settings screen is showing — where it did nothing.
  final bool inSettings;
  // In Nostalgia Mode a small unmarked nonsense button appears on the metal.
  final bool nostalgia;

  const BottomRail({
    super.key,
    required this.palette,
    required this.mode,
    required this.status,
    required this.onMode,
    this.inSettings = false,
    this.nostalgia = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Padding(
      // Inset on both sides so the controls sit in the screen space *between*
      // the two corner woofers, never under them.
      padding: const EdgeInsets.fromLTRB(72, 1, 72, 2),
      child: Row(
        children: [
          // TEXT / GRID rocker — only meaningful on the file list.
          if (!inSettings)
            Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: p.mv1,
                borderRadius: BorderRadius.circular(3),
              ),
              child: Row(
                children: [
                  _rocker('TEXT', mode == ViewMode.text, () => onMode(ViewMode.text)),
                  const SizedBox(width: 2),
                  _rocker('GRID', mode == ViewMode.grid, () => onMode(ViewMode.grid)),
                ],
              ),
            ),
          const Spacer(),
          if (nostalgia) ...[
            NonsenseButton(palette: p),
            const SizedBox(width: 8),
          ],
          _led(p),
        ],
      ),
    );
  }

  Widget _rocker(String label, bool on, VoidCallback onTap) {
    final p = palette;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(2),
          gradient: on
              ? LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [p.mb, p.m2],
                )
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: Fonts.chassis,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1,
            color: on ? p.a : p.mt,
            shadows: on ? [Shadow(color: p.a, blurRadius: 6)] : null,
          ),
        ),
      ),
    );
  }

  /// The LED reads the link: accent when reachable, amber-ish when unreachable,
  /// dim when in first run.
  Widget _led(Palette p) {
    final color = switch (status) {
      LinkStatus.ok => p.a,
      LinkStatus.connecting => p.glow,
      LinkStatus.firstRun => p.mt,
      _ => const Color(0xFFf5b942), // a warning cast for the unreachable states
    };
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        boxShadow: [BoxShadow(color: color, blurRadius: 7)],
      ),
    );
  }
}
