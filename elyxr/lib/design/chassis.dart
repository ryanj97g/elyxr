// The two halves of the design that hold everything else: the metal chassis
// and the phosphor tube recessed into it. "Everything behind the glass is the
// terminal. Everything on the metal is a physical control." (DESIGN.md)

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../util/platform_caps.dart';
import '../widgets/edge_light.dart';
import '../widgets/speakers.dart';
import 'tokens.dart';

/// The tinted metal chassis: a gradient body with a border and an inner
/// highlight, holding the top rail, the tube, and the bottom rail with a gap
/// between the three.
class Chassis extends StatelessWidget {
  final Palette palette;
  final Widget topRail;
  final Widget tube;
  final Widget bottomRail;
  /// Nostalgia Mode drives the whimsy: the corner woofers only go rave-reactive
  /// while it's on (they're a resting grille otherwise).
  final bool nostalgia;

  const Chassis({
    super.key,
    required this.palette,
    required this.topRail,
    required this.tube,
    required this.bottomRail,
    this.nostalgia = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Container(
      // Fill whatever the parent sizes us to. Desktop wraps this in a fixed
      // 440×944 box; mobile hands us a box shaped to the screen so the tube (and
      // the file list inside it) can stretch to the real bottom edge.
      width: double.infinity,
      height: double.infinity,
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          // 176deg ≈ nearly top-to-bottom, a touch off vertical.
          begin: const Alignment(-0.07, -1),
          end: const Alignment(0.07, 1),
          colors: [p.m1, p.m2, p.m3],
          stops: const [0.0, 0.22, 1.0],
        ),
        border: Border.all(color: p.mb, width: 1),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: Column(
              children: [
          // A machined-metal bevel: a bright highlight hairline catches the
          // light at the top edge, and a dark recessed hairline sits in shadow
          // at the bottom — together the panel reads as raised, brushed metal.
          Container(height: 1, color: p.mh),
          // Both rails are drag handles — grab the metal to move the window.
          // (The tube can't be one, or you couldn't scroll or click files.) We
          // use our own drag area rather than DragToMoveArea because that widget
          // maximizes on double-click, which the fixed-size window must never do
          // — and it stole double-clicks from the wordmark and nonsense button.
          _DragArea(child: topRail),
          const SizedBox(height: 8),
          Expanded(child: tube),
          const SizedBox(height: 8),
          _DragArea(child: bottomRail),
          const SizedBox(height: 2),
          // The recessed bottom hairline — the shadowed underside of the bevel.
          Container(height: 1, color: p.mv1),
              ],
            ),
          ),
          // Woofers moulded into the bottom corners: each covers the tube's
          // bottom corner beneath it (a reverse notch) and the end of the
          // bottom rail — which is why the rail's controls are inset to live in
          // the space between them.
          // The woofers thump to whatever's playing at all times; Nostalgia Mode
          // only cranks the intensity (the full light show — the edge glow — is
          // still Nostalgia-only, layered in the tube above).
          Positioned(
            left: 0,
            bottom: 0,
            child: CornerSpeaker(
                palette: p, left: true, reactive: true, intense: nostalgia),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: CornerSpeaker(
                palette: p, left: false, reactive: true, intense: nostalgia),
          ),
        ],
      ),
    );
  }
}

/// A window drag handle: moves the window on a drag, and — unlike
/// `DragToMoveArea` — does nothing on a double-click, so the fixed-size window
/// can never maximize and rapid clicks reach the controls beneath (the wordmark
/// count, the nonsense button). A tap falls through to the child; only actual
/// dragging moves the window.
class _DragArea extends StatelessWidget {
  final Widget child;
  const _DragArea({required this.child});

  @override
  Widget build(BuildContext context) {
    // Dragging the metal moves the OS window — only meaningful with a managed
    // window. On a phone there's nothing to drag, so the rails are just rails.
    if (!Caps.hasWindowManager) return child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => windowManager.startDragging(),
      child: child,
    );
  }
}

/// The CRT tube: the recessed glass. Paints its own background, bezel, vignette
/// and accent glow, then layers the scanlines, the slow sweep, and the subtle
/// flicker over the child terminal content.
class Tube extends StatelessWidget {
  final Palette palette;
  final Widget child;
  /// An optional top layer over the whole glass (the Matrix screensaver). When
  /// present it sits above everything, clipped to the tube.
  final Widget? overlay;
  /// The music-reactive edge lighting is Nostalgia Mode only.
  final bool nostalgia;

  const Tube(
      {super.key,
      required this.palette,
      required this.child,
      this.overlay,
      this.nostalgia = false});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.tubeBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF0A0C0B), width: 1),
      ),
      child: Stack(
        children: [
          // Bezel: a 3px recess ring just inside the border.
          Positioned.fill(
            child: Container(
              margin: const EdgeInsets.all(1),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(13),
                border: Border.all(color: p.mv1, width: 3),
              ),
            ),
          ),
          // The terminal content.
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: child,
            ),
          ),
          // Accent glow + vignette, drawn over content, non-interactive. The
          // dark ring is kept light enough that the corners stay legible — a
          // gentle falloff, not a heavy black frame.
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: RadialGradient(
                    radius: 1.2,
                    colors: [
                      // A soft phosphor bloom at the centre, falling to a gentle
                      // dark ring at the edges (legible corners, not a black
                      // frame). The bloom grows as the accent saturation maxes.
                      p.aAlpha(p.bloom),
                      Colors.black.withValues(alpha: p.dark ? 0.42 : 0.12),
                    ],
                    stops: const [0.6, 1.0],
                  ),
                ),
              ),
            ),
          ),
          // The moving scan beam.
          Positioned.fill(
            child: IgnorePointer(child: _Sweep(palette: p)),
          ),
          // Static scanlines on top of everything. Cached to a layer with a
          // RepaintBoundary so scaling the fixed chassis to the window resamples
          // one rasterised texture instead of re-drawing crisp hairlines each
          // frame — which is what made them shimmer.
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(painter: _ScanlinePainter(p.a)),
              ),
            ),
          ),
          // The screensaver (or any full-glass overlay), clipped to the tube and
          // above the scanlines — it's its own screen state. (It fades itself
          // in.)
          if (overlay != null)
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: overlay,
              ),
            ),
          // Music-reactive edge lighting, framing everything else. Clipped to the
          // glass so the bloom stays on-screen; invisible until music plays —
          // and only in Nostalgia Mode.
          if (nostalgia)
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: EdgeLight(palette: p),
              ),
            ),
        ],
      ),
    );
  }
}

/// Hairline scanlines every 4px — a faint *phosphor-tinted* line so the raster
/// glows on the near-black tube instead of a dark line vanishing into it.
class _ScanlinePainter extends CustomPainter {
  final Color accent;
  const _ScanlinePainter(this.accent);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = accent.withValues(alpha: 0.08)
      ..strokeWidth = 1;
    for (double y = 3; y < size.height; y += 4) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ScanlinePainter old) => old.accent != accent;
}

/// A single scanner line that sweeps from the very top of the tube to the
/// bottom once every ~7s — a quick, near-invisible pass, then a long rest.
/// Drawn by a painter at an exact Y so `y=0` is genuinely the top edge (right
/// under the top rail) and `y=h` the bottom — no fill-constraint stretching.
class _Sweep extends StatefulWidget {
  final Palette palette;
  const _Sweep({required this.palette});

  @override
  State<_Sweep> createState() => _SweepState();
}

class _SweepState extends State<_Sweep> with SingleTickerProviderStateMixin {
  // One pass every 11 seconds. The sweep itself is quick; the rest of the cycle
  // is quiet, so it reads as a periodic sonar pass, not constant motion.
  static const _cycle = Duration(seconds: 11);
  // Fraction of the cycle spent actually moving. Kept short in absolute terms
  // (~1.7s) so the pass stays quick as the cycle lengthens.
  static const double _sweepPart = 0.155;

  late final AnimationController _c =
      AnimationController(vsync: this, duration: _cycle)..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value;
          // progress 0→1 down the tube during the sweep window, else resting.
          final progress = t < _sweepPart ? t / _sweepPart : null;
          return CustomPaint(
            size: Size.infinite,
            painter: _SweepPainter(widget.palette.a, progress),
          );
        },
      ),
    );
  }
}

/// Paints the scanner line: a thin, only-just-visible hairline with the
/// faintest glow feathered around it. Nothing when resting.
class _SweepPainter extends CustomPainter {
  final Color accent;
  final double? progress; // null while resting between passes
  const _SweepPainter(this.accent, this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    final p = progress;
    if (p == null) return;
    final y = size.height * p;
    // A soft glow feathered a few px either side of the line — a tad more
    // present now, still gentle.
    final glow = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          accent.withValues(alpha: 0),
          accent.withValues(alpha: 0.08),
          accent.withValues(alpha: 0),
        ],
      ).createShader(Rect.fromLTWH(0, y - 7, size.width, 14));
    canvas.drawRect(Rect.fromLTWH(0, y - 7, size.width, 14), glow);
    // The crisp line itself — thin, a touch brighter.
    final line = Paint()
      ..color = accent.withValues(alpha: 0.2)
      ..strokeWidth = 1.2;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
  }

  @override
  bool shouldRepaint(covariant _SweepPainter old) =>
      old.progress != progress || old.accent != accent;
}
