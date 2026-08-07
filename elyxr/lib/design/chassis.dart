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

/// A soft glowing scan bar that sweeps top to bottom over 8s, looping. Its
/// bright centre rides the scan position, so at the start of each pass it sits
/// right at the top and moves smoothly down — a visible scan, not a thin edge.
class _Sweep extends StatefulWidget {
  final Palette palette;
  const _Sweep({required this.palette});

  @override
  State<_Sweep> createState() => _SweepState();
}

class _SweepState extends State<_Sweep> with SingleTickerProviderStateMixin {
  // A thin bright line — a scanner line that lights only a hairline as it
  // passes, so it can't drag a lit band across the static phosphor texture.
  static const double _band = 6;
  // Fraction of the cycle spent sweeping; the rest is a brief rest, so the
  // line reads as a periodic sonar pass, not constant motion.
  static const double _sweepPart = 0.7;

  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 3200))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final h = constraints.maxHeight;
          return AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              final t = _c.value;
              if (t > _sweepPart) return const SizedBox.shrink(); // resting
              // A single line crosses the whole tube: its centre runs from the
              // very top (y=0) to the bottom (y=h) during the sweep window.
              final y = h * (t / _sweepPart);
              return Transform.translate(
                offset: Offset(0, y - _band / 2),
                child: Container(
                  height: _band,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      // A clean bright line — a hair of feather so it isn't
                      // aliased, no glow-bar spread.
                      colors: [
                        p.aAlpha(0),
                        p.aAlpha(0.65),
                        p.aAlpha(0),
                      ],
                      stops: const [0.2, 0.5, 0.8],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
