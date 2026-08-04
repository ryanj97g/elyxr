// The two halves of the design that hold everything else: the metal chassis
// and the phosphor tube recessed into it. "Everything behind the glass is the
// terminal. Everything on the metal is a physical control." (DESIGN.md)

import 'package:flutter/material.dart';

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
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.58),
            blurRadius: 42,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: Column(
        children: [
          // Inner highlight (inset 0 1px 0 mh): a hairline at the very top.
          Container(height: 1, color: p.mh),
          topRail,
          const SizedBox(height: 8),
          Expanded(child: tube),
          const SizedBox(height: 8),
          bottomRail,
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
    return Flicker(
      child: DecoratedBox(
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
            // Accent glow + vignette, drawn over content, non-interactive.
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    gradient: RadialGradient(
                      radius: 1.1,
                      colors: [
                        p.aAlpha(p.dark ? 0.04 : 0.0),
                        Colors.black.withValues(alpha: p.dark ? 0.85 : 0.22),
                      ],
                      stops: const [0.55, 1.0],
                    ),
                  ),
                ),
              ),
            ),
            // The moving sweep band.
            Positioned.fill(
              child: IgnorePointer(child: _Sweep(palette: p)),
            ),
            // Scanlines on top of everything.
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(painter: _ScanlinePainter()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// `repeating-linear-gradient(180deg, transparent 0 2px, rgba(0,0,0,0.32) 3px 4px)`
class _ScanlinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black.withValues(alpha: 0.32)
      ..strokeWidth = 1;
    for (double y = 3; y < size.height; y += 4) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// The 120px band that slides down the tube over 8s, looping (DESIGN.md).
class _Sweep extends StatefulWidget {
  final Palette palette;
  const _Sweep({required this.palette});

  @override
  State<_Sweep> createState() => _SweepState();
}

class _SweepState extends State<_Sweep> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 8))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return LayoutBuilder(
      builder: (context, constraints) {
        final h = constraints.maxHeight;
        return AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            // Travel from just above the top to just past the bottom.
            final y = -120.0 + (h + 120.0) * _c.value;
            return Transform.translate(
              offset: Offset(0, y),
              child: Container(
                height: 120,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      p.aAlpha(0),
                      p.aAlpha(0.05),
                      p.aAlpha(0.10),
                    ],
                    stops: const [0, 0.72, 1],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Opacity 1, dipping to 0.88 at 94% and 0.94 at 97% of a 9s loop. Subtle.
class Flicker extends StatefulWidget {
  final Widget child;
  const Flicker({super.key, required this.child});

  @override
  State<Flicker> createState() => _FlickerState();
}

class _FlickerState extends State<Flicker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 9))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  double _opacityAt(double t) {
    // Piecewise, matching the CSS keyframes.
    if (t < 0.92) return 1.0;
    if (t < 0.94) return _lerp(1.0, 0.88, (t - 0.92) / 0.02);
    if (t < 0.97) return _lerp(0.88, 0.94, (t - 0.94) / 0.03);
    return _lerp(0.94, 1.0, (t - 0.97) / 0.03);
  }

  double _lerp(double a, double b, double f) => a + (b - a) * f;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) =>
          Opacity(opacity: _opacityAt(_c.value), child: child),
      child: widget.child,
    );
  }
}
