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
import '../util/platform_caps.dart';
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

class _TopRailState extends State<TopRail> with SingleTickerProviderStateMixin {
  bool _holding = false;
  Timer? _timer;
  // A quick-tap counter, distinct from the hold — seven in a row is the egg.
  int _taps = 0;
  Timer? _tapReset;

  // The idle wordmark gleam: a short faint sweep, fired on a gentle repeat, as
  // the only hint that ELYXR is pressable (hold it for settings).
  late final AnimationController _shine =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
  Timer? _shineTimer;

  @override
  void initState() {
    super.initState();
    _shineTimer = Timer.periodic(const Duration(milliseconds: 4500), (_) {
      if (mounted && !widget.inSettings && !_holding) _shine.forward(from: 0);
    });
  }

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
    _shineTimer?.cancel();
    _shine.dispose();
    super.dispose();
  }

  /// The wordmark. The letters look and behave exactly as before: the same
  /// metal-light mark with its 1px emboss, and the caller's tap/hold gesture that
  /// opens Settings is untouched. ONLY the idle gleam is rebuilt. The letters are
  /// the WINDOW: drawn once as a text-shaped mask onto a base fill plus a diagonal
  /// light stripe that sweeps across behind them (a cutout, not an overlay). The
  /// stripe never aligns to the glyphs, it just passes behind them, so there is
  /// nothing to size-match and nothing that can drift or pulse. While lit
  /// (Settings/holding) it glows the accent, no gleam, unchanged.
  Widget _wordmark(Palette p, bool lit) {
    const emboss = [Shadow(color: Color(0xFF0C0D0F), offset: Offset(0, 1))];
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    // Lit or reduce-motion: no gleam. The mark sits in its colour (accent when
    // lit, with a glow); AnimatedDefaultTextStyle eases the light-up on a hold.
    if (lit || reduceMotion) {
      return Padding(
        padding: const EdgeInsets.only(left: 6),
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 200),
          style: TextStyle(
            fontFamily: Fonts.chassis,
            fontSize: 15,
            fontWeight: FontWeight.w700,
            letterSpacing: lit ? 15 * 0.24 : 15 * 0.4,
            color: lit ? p.a : p.ml,
            shadows: lit ? [Shadow(color: p.a, blurRadius: 11)] : emboss,
          ),
          child: const Text('ELYXR'),
        ),
      );
    }

    // Idle: the letters are a window. They're rendered exactly once, as a
    // text-shaped mask, over a base fill (their resting colour) plus a diagonal
    // light stripe that sweeps behind them. At rest the fill is a flat p.ml and
    // the mark is pixel-identical to before; mid-sweep the stripe passes
    // through. The glyph geometry never moves, so nothing can pulse or drift.
    final glyph = TextStyle(
      fontFamily: Fonts.chassis,
      fontSize: 15,
      fontWeight: FontWeight.w700,
      letterSpacing: 15 * 0.4,
    );
    final probe = TextPainter(
      text: TextSpan(text: 'ELYXR', style: glyph),
      textDirection: TextDirection.ltr,
    )..layout();

    return Padding(
      padding: const EdgeInsets.only(left: 6),
      // One px of headroom below so the 1px emboss isn't clipped.
      child: SizedBox(
        width: probe.width,
        height: probe.height + 1,
        child: AnimatedBuilder(
          animation: _shine,
          builder: (context, _) => CustomPaint(
            painter: _WordmarkGleam(
              base: p.ml,
              // A near-white metallic flash for the sweep, as specced: a clean
              // light stripe crossing the silver, not a coloured glow.
              highlight: Color.lerp(p.ml, const Color(0xFFFFFFFF), 0.9)!,
              glyph: glyph,
              t: _shine.value,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final lit = widget.inSettings || _holding;
    return Padding(
      padding: const EdgeInsets.fromLTRB(3, 1, 3, 0),
      child: Row(
        children: [
          // Left screw quietly minimizes the window (desktop only — no window to
          // minimize on a phone).
          _screw(p,
              onTap: Caps.hasWindowManager ? () => windowManager.minimize() : null,
              tip: 'Minimize'),
          const SizedBox(width: 9),
          GestureDetector(
            onTapDown: (_) => _press(),
            onTapUp: (_) => _release(),
            onTapCancel: _release,
            onTap: _tap,
            behavior: HitTestBehavior.opaque,
            child: _wordmark(p, lit),
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
          // Right screw quietly closes the window (desktop only).
          _screw(p,
              onTap: Caps.hasWindowManager ? () => windowManager.close() : null,
              tip: 'Close'),
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

/// Draws the idle wordmark so the letters are the only thing painted: the base
/// colour (and, mid-sweep, a diagonal light stripe) confined to the exact shape
/// of the glyphs, with the same 1px dark emboss beneath. The letters are drawn
/// once as an opaque mask, then the fill and the stripe are clipped to that mask
/// (srcIn/srcATop), so nothing ever escapes the glyphs and nothing pulses or
/// drifts. When [t] is 0 or 1 (resting) it's a flat base fill: pixel-identical
/// to the plain mark.
class _WordmarkGleam extends CustomPainter {
  final Color base;
  final Color highlight;
  final TextStyle glyph;
  final double t; // sweep position 0..1; only 0<t<1 shows the stripe
  const _WordmarkGleam({
    required this.base,
    required this.highlight,
    required this.glyph,
    required this.t,
  });

  TextPainter _paintFor(Color c) => TextPainter(
        text: TextSpan(text: 'ELYXR', style: glyph.copyWith(color: c)),
        textDirection: TextDirection.ltr,
      )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    // The emboss: the same dark shadow one pixel down, painted first so it sits
    // behind the mark (matches the const emboss used on the lit/reduced path).
    _paintFor(const Color(0xFF0C0D0F)).paint(canvas, const Offset(0, 1));

    // Everything below composites in its own layer so the fill and stripe can be
    // clipped to the letter shape without touching the emboss beneath.
    final bounds = Offset.zero & size;
    canvas.saveLayer(bounds, Paint());

    // 1) The letters themselves, opaque. This is the shape; colour here is only
    // a placeholder, the fill in step 2 replaces it.
    _paintFor(const Color(0xFFFFFFFF)).paint(canvas, Offset.zero);

    // 2) The resting colour, kept only where the letters are (srcIn reads the
    // letters' alpha). At rest this is all that shows: the plain mark.
    canvas.drawRect(
      bounds,
      Paint()
        ..color = base
        ..blendMode = BlendMode.srcIn,
    );

    // 3) The gleam: a diagonal light stripe crossing the letters left to right,
    // wider than any glyph and rotated so it never lines up with the text. srcATop
    // keeps it strictly inside the letters. A thinner parallel streak trails it.
    if (t > 0.0 && t < 1.0) {
      final w = size.width, h = size.height;
      canvas.save();
      // Travel the stripe's centre from off the left edge to off the right.
      final cx = -0.45 * w + t * 1.9 * w;
      canvas.translate(cx, h / 2);
      canvas.rotate(-0.52); // ~30 degrees off vertical
      canvas.drawRect(
        Rect.fromCenter(center: Offset.zero, width: 11, height: h * 3),
        Paint()
          ..color = highlight.withValues(alpha: 0.7)
          ..blendMode = BlendMode.srcATop
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
      canvas.drawRect(
        Rect.fromCenter(center: const Offset(10, 0), width: 3.5, height: h * 3),
        Paint()
          ..color = highlight.withValues(alpha: 0.4)
          ..blendMode = BlendMode.srcATop
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
      );
      canvas.restore();
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WordmarkGleam old) =>
      old.t != t || old.base != base || old.highlight != highlight;
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
  // The screensaver lightshow is up: hide the TEXT/GRID rocker so nothing sits
  // out of place over it.
  final bool saver;

  const BottomRail({
    super.key,
    required this.palette,
    required this.mode,
    required this.status,
    required this.onMode,
    this.inSettings = false,
    this.nostalgia = false,
    this.saver = false,
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
          // TEXT / GRID rocker — only meaningful on the file list, and hidden
          // while settings or the screensaver is showing.
          if (!inSettings && !saver)
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
