// A Nostalgia-Mode cursor trail: little ghost arrows fade behind the pointer, in
// the accent colour — the classic '90s "pointer trails" toy, reborn as phosphor
// persistence. Desktop only in practice: it feeds on hover events, of which
// touch has none, so it simply draws nothing there.

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../../design/tokens.dart';

class _Ghost {
  final Offset pos;
  final double birth; // seconds
  const _Ghost(this.pos, this.birth);
}

class CursorTrail extends StatefulWidget {
  /// The live pointer position (in this overlay's coordinate space), pushed by
  /// the app's top-level Listener. Null when the pointer isn't over the window.
  final ValueNotifier<Offset?> cursor;
  final Palette palette;
  const CursorTrail({super.key, required this.cursor, required this.palette});

  @override
  State<CursorTrail> createState() => _CursorTrailState();
}

class _CursorTrailState extends State<CursorTrail>
    with SingleTickerProviderStateMixin {
  final List<_Ghost> _ghosts = [];
  final ValueNotifier<int> _repaint = ValueNotifier(0);
  late final Ticker _ticker;
  double _now = 0;
  Offset? _last;

  static const double _life = 0.55; // seconds a ghost lingers
  static const double _spacing = 7; // min px between dropped ghosts

  @override
  void initState() {
    super.initState();
    widget.cursor.addListener(_onCursor);
    _ticker = createTicker((e) {
      _now = e.inMicroseconds / 1e6;
      final before = _ghosts.length;
      _ghosts.removeWhere((g) => _now - g.birth > _life);
      // Repaint while anything is still fading (or just changed).
      if (_ghosts.isNotEmpty || before != 0) _repaint.value++;
    })..start();
  }

  void _onCursor() {
    final p = widget.cursor.value;
    if (p == null) return;
    if (_last == null || (p - _last!).distance >= _spacing) {
      _ghosts.add(_Ghost(p, _now));
      _last = p;
      if (_ghosts.length > 40) _ghosts.removeAt(0);
    }
  }

  @override
  void dispose() {
    widget.cursor.removeListener(_onCursor);
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _TrailPainter(_repaint, _ghosts, () => _now, widget.palette.a),
      ),
    );
  }
}

class _TrailPainter extends CustomPainter {
  final List<_Ghost> ghosts;
  final double Function() now;
  final Color accent;

  _TrailPainter(Listenable repaint, this.ghosts, this.now, this.accent)
      : super(repaint: repaint);

  // A small classic pointer-arrow, drawn at the origin; the painter translates it
  // to each ghost.
  static final Path _arrow = Path()
    ..moveTo(0, 0)
    ..lineTo(0, 14)
    ..lineTo(3.6, 10.6)
    ..lineTo(6.1, 16.2)
    ..lineTo(8.0, 15.4)
    ..lineTo(5.6, 9.8)
    ..lineTo(10, 9.8)
    ..close();

  @override
  void paint(Canvas canvas, Size size) {
    final t = now();
    for (final g in ghosts) {
      final age = ((t - g.birth) / _CursorTrailState._life).clamp(0.0, 1.0);
      final a = (1 - age) * 0.55;
      if (a <= 0.01) continue;
      canvas.save();
      canvas.translate(g.pos.dx, g.pos.dy);
      canvas.drawPath(_arrow, Paint()..color = accent.withValues(alpha: a));
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _TrailPainter old) => old.accent != accent;
}
