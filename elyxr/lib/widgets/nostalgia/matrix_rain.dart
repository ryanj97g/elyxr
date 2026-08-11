// The Matrix screensaver: falling glyphs on a black tube, in the user's accent
// colour (so it re-colours live with the phosphor — a moving demo of the theme
// system). Shown only in Nostalgia Mode after the app sits idle; any interaction
// dismisses it. Self-contained: its own ticker, its own painter.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../../design/tokens.dart';

/// One column's fixed character — how fast it falls, where it starts, and how
/// long its tail is. Precomputed once so the rain is stable frame to frame.
class _Column {
  final double speed; // cells per second
  final double offset; // starting head position, in cells
  final int trail; // tail length, in cells
  final int phase; // seed for which glyphs it shows
  const _Column(this.speed, this.offset, this.trail, this.phase);
}

class MatrixRain extends StatefulWidget {
  final Palette palette;
  const MatrixRain({super.key, required this.palette});

  @override
  State<MatrixRain> createState() => _MatrixRainState();
}

class _MatrixRainState extends State<MatrixRain>
    with SingleTickerProviderStateMixin {
  // Elapsed seconds since the rain started, driven by a Ticker. A ValueNotifier
  // so the painter repaints without rebuilding the widget tree each frame.
  final ValueNotifier<double> _t = ValueNotifier(0);
  late final Ticker _ticker;

  // A generous pool of column characters; the painter indexes into it by column,
  // wrapping, so any tube width is covered.
  late final List<_Column> _columns;

  @override
  void initState() {
    super.initState();
    final rnd = math.Random(1337); // fixed seed → the same rain every session
    _columns = List.generate(80, (_) {
      return _Column(
        6 + rnd.nextDouble() * 16, // 6–22 cells/sec
        rnd.nextDouble() * 40, // staggered starts
        8 + rnd.nextInt(16), // tails 8–23 cells
        rnd.nextInt(100000),
      );
    });
    _ticker = createTicker((e) => _t.value = e.inMicroseconds / 1e6)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Fade the tube to black-and-rain over ~1.2s, so it eases in rather than
    // snapping on.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 1200),
      curve: Curves.easeIn,
      builder: (context, opacity, child) =>
          Opacity(opacity: opacity, child: child),
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: _RainPainter(
            _t,
            _columns,
            head: widget.palette.hot,
            trail: widget.palette.a,
            face: Fonts.glass,
          ),
        ),
      ),
    );
  }
}

class _RainPainter extends CustomPainter {
  final ValueNotifier<double> time;
  final List<_Column> columns;
  final Color head;
  final Color trail;
  final String face;

  _RainPainter(this.time, this.columns,
      {required this.head, required this.trail, required this.face})
      : super(repaint: time);

  // Half-width katakana, digits, and a few symbols — the classic rain alphabet.
  static const _glyphs =
      'アイウエオカキクケコサシスセソタチツテトナニヌネノﾊﾋﾌﾍﾎマミムメモﾔﾕﾖﾗﾘﾙﾚﾛﾜ0123456789:.=*+<>¦｜ー';

  // A denser grid — smaller cells fit several more columns of rain on screen.
  static const double _cell = 11.5;

  @override
  void paint(Canvas canvas, Size size) {
    // The tube fades to black behind the rain.
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF000000));

    final t = time.value;
    final cols = (size.width / _cell).ceil();
    final rows = (size.height / _cell).ceil();
    final tp = TextPainter(textDirection: TextDirection.ltr);

    for (var c = 0; c < cols; c++) {
      final col = columns[c % columns.length];
      final span = rows + col.trail + 4;
      final headPos = (t * col.speed + col.offset) % span;
      for (var k = 0; k < col.trail; k++) {
        final row = (headPos - k).floor();
        if (row < 0 || row > rows) continue;
        final isHead = k == 0;
        final frac = 1 - k / col.trail;
        final color = isHead
            ? head
            : trail.withValues(alpha: (frac * frac * 0.9).clamp(0.06, 1.0));
        // A glyph that flips occasionally as the column falls.
        final gi = (col.phase + row * 17 + (t * 6).floor() * (row.isEven ? 1 : 0)) %
            _glyphs.length;
        tp.text = TextSpan(
          text: _glyphs[gi],
          style: TextStyle(
            color: color,
            fontSize: 11.5,
            fontFamily: face,
            fontFamilyFallback: Fonts.fallback,
            height: 1.0,
          ),
        );
        tp.layout();
        tp.paint(canvas, Offset(c * _cell + 1, row * _cell));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _RainPainter old) =>
      old.head != head || old.trail != trail || old.face != face;
}
