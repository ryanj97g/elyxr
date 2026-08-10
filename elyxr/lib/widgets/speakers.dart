// The woofers: just the drivers. Each one sits in a hole in the chassis metal —
// the cradle cut out of the glass at a bottom corner (see notchedTubePath and
// Tube._driver) — so the metal wrapping it is the case's own surface.
//
// This file paints NO metal. It used to draw its own 66x66 metal pod with its own
// gradient, its own bright outline and its own contact shadow, which is precisely
// why the speakers read as parts stuck onto the case rather than moulded into it:
// a tile with an outline is a separate object no matter how well it's shaded. All
// of that is gone. What's left is the recess rim, the basket, the cone and the
// dust cap — a driver, and nothing it's bolted to.
//
// The cone bumps to the music's bass. Not faked: it comes from the same live
// spectrum the visualizer uses (MusicController.visualizerBars, off the play
// head). Still a resting driver when nothing's playing.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:provider/provider.dart';

import '../design/tokens.dart';
import '../state/music.dart';

class CornerSpeaker extends StatefulWidget {
  final Palette palette;
  /// When false the woofer is just a resting driver. It thumps to whatever is
  /// playing whenever this is true.
  final bool reactive;
  /// Nostalgia Mode: crank the bass response so the cone really slams. Off, the
  /// woofer still bumps to the music, just gentler.
  final bool intense;
  const CornerSpeaker(
      {super.key,
      required this.palette,
      this.reactive = false,
      this.intense = false});

  @override
  State<CornerSpeaker> createState() => _CornerSpeakerState();
}

class _CornerSpeakerState extends State<CornerSpeaker>
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
    // Off Nostalgia, the woofer never reacts — settle to rest and stop.
    if (!widget.reactive) {
      if (_level != 0) {
        _level = 0;
        _bass.value = 0;
      }
      return;
    }
    final m = context.read<MusicController>();
    final bars = m.playing ? m.visualizerBars() : const <double>[];
    var bass = 0.0;
    if (bars.isNotEmpty) {
      final n = math.min(4, bars.length); // the low bands
      for (var i = 0; i < n; i++) {
        bass += bars[i];
      }
      bass /= n;
    }
    // Exaggerate so a hit reads as a real thump, not a shimmer — harder in
    // Nostalgia Mode (the rave), softer otherwise (a normal woofer).
    bass = (bass * (widget.intense ? 1.7 : 1.05)).clamp(0.0, 1.0);
    // Instant attack, snappy decay — BOOM, then fall fast.
    _level = bass > _level ? bass : _level * 0.72 + bass * 0.28;
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
    return RepaintBoundary(
      child: ValueListenableBuilder<double>(
        valueListenable: _bass,
        builder: (_, v, __) => CustomPaint(
          painter: _CornerSpeakerPainter(widget.palette, v.clamp(0.0, 1.0)),
        ),
      ),
    );
  }
}

// The deep case shadow used for the moulded recesses and contact shadows.
const Color _deep = Color(0xFF05070A);

class _CornerSpeakerPainter extends CustomPainter {
  final Palette p;
  final double level; // 0..1 bass energy now
  const _CornerSpeakerPainter(this.p, this.level);

  @override
  void paint(Canvas canvas, Size size) {
    // The box is the whole dome, so the driver is centred in it and the boom has
    // room to spill onto the metal around it.
    final c = size.center(Offset.zero);
    const r = kDriverR;

    // The rim of the hole the driver is set into. Dark at the top where the metal
    // above overhangs it, lightening at the bottom where light bounces back up —
    // the inverse of a raised part, which is what makes it read as sunk INTO the
    // case rather than sitting on it. This is the only edge drawn anywhere near
    // the speaker; there is deliberately no ring around anything.
    canvas.drawCircle(
      c,
      r + 1.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_deep, p.mh.withValues(alpha: 0.5)],
        ).createShader(Rect.fromCircle(center: c, radius: r + 1.5)),
    );

    // The basket well: dark at the top lifting to a little light at the bottom,
    // with an inner-rim shadow deepening the recess.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_deep, p.m2],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = _deep.withValues(alpha: 0.7)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
    );

    // The BOOM: a wide, bright accent flare plus an expanding shockwave ring,
    // punching out on every beat. This is the rave — it spills past the basket
    // onto the metal on the hardest hits.
    if (level > 0.01) {
      final lv = level;
      canvas.drawCircle(
        c,
        r * (1 + lv * 0.95),
        Paint()
          ..color = p.a.withValues(alpha: (lv * 0.85).clamp(0.0, 1.0))
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 6 + 22 * lv),
      );
      canvas.drawCircle(
        c,
        r * (0.8 + lv * 0.7),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5 + 3 * lv
          ..color = p.a.withValues(alpha: (lv * 0.7).clamp(0.0, 1.0))
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 1 + 3 * lv),
      );
    }

    // The cone — real travel now, and it lights toward the accent as it slams.
    final coneR = (r * (0.58 + level * 0.36)).clamp(0.0, r - 1.5);
    canvas.drawCircle(
      c,
      coneR,
      Paint()..color = Color.lerp(p.m3, p.a, (level * 0.55).clamp(0.0, 1.0))!,
    );
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = p.mv1;
    canvas.drawCircle(c, coneR * 0.72, ring);
    canvas.drawCircle(c, coneR * 0.46, ring);

    // The dust cap flares hard and swells on the hit.
    canvas.drawCircle(
      c,
      coneR * (0.24 + level * 0.16),
      Paint()..color = Color.lerp(p.mt, p.a, (level * 1.3).clamp(0.0, 1.0))!,
    );
  }

  @override
  bool shouldRepaint(covariant _CornerSpeakerPainter old) =>
      old.level != level || old.p != p;
}
