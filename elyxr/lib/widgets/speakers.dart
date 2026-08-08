// Two little woofers on the bottom rail that bump to the music. Not faked: they
// read the same live spectrum the visualizer does (MusicController.visualizerBars,
// sampled off the play head), take the low end, and push the cone + glow on the
// bass. Still metal grilles when nothing's playing.

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:provider/provider.dart';

import '../design/tokens.dart';
import '../state/music.dart';

class SpeakerPair extends StatefulWidget {
  final Palette palette;
  final double size;
  const SpeakerPair({super.key, required this.palette, this.size = 20});

  @override
  State<SpeakerPair> createState() => _SpeakerPairState();
}

class _SpeakerPairState extends State<SpeakerPair>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  double _level = 0;
  final _bass = ValueNotifier<double>(0);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick)..start();
  }

  void _tick(Duration _) {
    final music = context.read<MusicController>();
    final bars = music.playing ? music.visualizerBars() : const <double>[];
    var bass = 0.0;
    if (bars.isNotEmpty) {
      // The lowest few bands are the bass — average them.
      final n = bars.length < 4 ? bars.length : 4;
      for (var i = 0; i < n; i++) {
        bass += bars[i];
      }
      bass /= n;
    }
    // Instant push, quick-but-smooth settle — a cone thumping, not a wobble.
    _level = bass > _level ? bass : _level * 0.80 + bass * 0.20;
    _bass.value = _level;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _bass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Woofer(level: _bass, palette: p, size: widget.size),
        const SizedBox(width: 9),
        _Woofer(level: _bass, palette: p, size: widget.size),
      ],
    );
  }
}

class _Woofer extends StatelessWidget {
  final ValueListenable<double> level;
  final Palette palette;
  final double size;
  const _Woofer(
      {required this.level, required this.palette, required this.size});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<double>(
        valueListenable: level,
        builder: (_, v, __) => CustomPaint(
          size: Size(size, size),
          painter: _WooferPainter(palette, v.clamp(0.0, 1.0)),
        ),
      ),
    );
  }
}

class _WooferPainter extends CustomPainter {
  final Palette p;
  final double level; // 0..1 bass energy right now
  const _WooferPainter(this.p, this.level);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;

    // The bass glow behind the cone — brighter and wider as it thumps.
    if (level > 0.02) {
      canvas.drawCircle(
        c,
        r * (1 + level * 0.35),
        Paint()
          ..color = p.a.withValues(alpha: (level * 0.55).clamp(0.0, 1.0))
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2 + 4 * level),
      );
    }

    // The basket: a metal ring.
    canvas.drawCircle(c, r - 0.5, Paint()..color = p.m2);
    canvas.drawCircle(
        c,
        r - 0.5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = p.mh);

    // The cone — pushes outward on the beat (a woofer moving air).
    final coneR = ((r - 2.5) * (1 + level * 0.14)).clamp(0.0, r - 1);
    canvas.drawCircle(c, coneR, Paint()..color = p.m3);
    // A couple of surround rings for the grille look.
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = p.mv1;
    canvas.drawCircle(c, coneR * 0.72, ring);
    canvas.drawCircle(c, coneR * 0.44, ring);

    // The dust cap in the middle, lighting up in the accent as the bass hits.
    canvas.drawCircle(
      c,
      coneR * 0.28,
      Paint()..color = Color.lerp(p.mt, p.a, level.clamp(0.0, 1.0))!,
    );
  }

  @override
  bool shouldRepaint(covariant _WooferPainter old) =>
      old.level != level || old.p != p;
}
