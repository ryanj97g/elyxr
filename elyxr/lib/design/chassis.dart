// The two halves of the design that hold everything else: the metal chassis
// and the phosphor tube recessed into it. "Everything behind the glass is the
// terminal. Everything on the metal is a physical control." (DESIGN.md)

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'tokens.dart';

/// The tinted metal chassis: a gradient body with a border and an inner
/// highlight, holding the top rail, the tube, and the bottom rail with a gap
/// between the three.
class Chassis extends StatelessWidget {
  final Palette palette;
  final Widget topRail;
  final Widget tube;
  final Widget bottomRail;

  const Chassis({
    super.key,
    required this.palette,
    required this.topRail,
    required this.tube,
    required this.bottomRail,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Container(
      width: kAppWidth,
      height: kAppHeight,
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
      child: Column(
        children: [
          // Inner highlight (inset 0 1px 0 mh): a hairline at the very top.
          Container(height: 1, color: p.mh),
          // Both rails are drag handles — grab the metal to move the window.
          // (The tube can't be one, or you couldn't scroll or click files.)
          DragToMoveArea(child: topRail),
          const SizedBox(height: 8),
          Expanded(child: tube),
          const SizedBox(height: 8),
          DragToMoveArea(child: bottomRail),
        ],
      ),
    );
  }
}

/// The CRT tube: the recessed glass. Paints its own background, bezel, vignette
/// and accent glow, then layers the scanlines, the slow sweep, and the subtle
/// flicker over the child terminal content.
class Tube extends StatelessWidget {
  final Palette palette;
  final Widget child;

  const Tube({super.key, required this.palette, required this.child});

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
                      // dark ring at the edges (legible corners, not a black frame).
                      p.aAlpha(p.dark ? 0.07 : 0.0),
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
  // One pass every 7 seconds. The sweep itself is quick; the rest of the cycle
  // is quiet, so it reads as a periodic sonar pass, not constant motion.
  static const _cycle = Duration(seconds: 7);
  // Fraction of the cycle spent actually moving.
  static const double _sweepPart = 0.24;

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
    // A barely-there glow feathered a few px either side of the line.
    final glow = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          accent.withValues(alpha: 0),
          accent.withValues(alpha: 0.05),
          accent.withValues(alpha: 0),
        ],
      ).createShader(Rect.fromLTWH(0, y - 6, size.width, 12));
    canvas.drawRect(Rect.fromLTWH(0, y - 6, size.width, 12), glow);
    // The crisp line itself — thin, and close to translucent.
    final line = Paint()
      ..color = accent.withValues(alpha: 0.13)
      ..strokeWidth = 1.2;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
  }

  @override
  bool shouldRepaint(covariant _SweepPainter old) =>
      old.progress != progress || old.accent != accent;
}
