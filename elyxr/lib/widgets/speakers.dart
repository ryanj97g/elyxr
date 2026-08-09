// Woofers built into the bottom corners of the chassis. Each is a metal pod
// shaped to the corner — it covers the tube's corner underneath (a reverse
// notch), so the screen reads as moulded around a real speaker — with a grille
// that bumps to the music's bass. Not faked: the bass comes from the same live
// spectrum the visualizer uses (MusicController.visualizerBars, off the play
// head). Still a metal grille when nothing's playing.

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:provider/provider.dart';

import '../design/tokens.dart';
import '../state/music.dart';

class CornerSpeaker extends StatefulWidget {
  final Palette palette;
  final bool left; // bottom-left vs bottom-right — corner shaping mirrors.
  final double size;
  /// When false the woofer is just a resting metal grille. It thumps to whatever
  /// is playing whenever this is true.
  final bool reactive;
  /// Nostalgia Mode: crank the bass response so the cone really slams. Off, the
  /// woofer still bumps to the music, just gentler.
  final bool intense;
  const CornerSpeaker(
      {super.key,
      required this.palette,
      required this.left,
      this.reactive = false,
      this.intense = false,
      this.size = 66});

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
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: ValueListenableBuilder<double>(
          valueListenable: _bass,
          builder: (_, v, __) => CustomPaint(
            painter: _CornerSpeakerPainter(
                widget.palette, v.clamp(0.0, 1.0), widget.left),
          ),
        ),
      ),
    );
  }
}

class _CornerSpeakerPainter extends CustomPainter {
  final Palette p;
  final double level; // 0..1 bass energy now
  final bool left;
  const _CornerSpeakerPainter(this.p, this.level, this.left);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // The metal pod filling the corner. The OUTER corner (the chassis corner)
    // rounds to the chassis radius; the INNER corner (facing the screen) rounds
    // larger, so the tube appears to curve around the speaker — the reverse
    // notch. The pod covers whatever tube corner is beneath it.
    const outer = Radius.circular(8); // matches the chassis border radius
    const notch = Radius.circular(20); // the screen's curve around the woofer
    const small = Radius.circular(3);
    final pod = left
        ? RRect.fromRectAndCorners(rect,
            bottomLeft: outer, topRight: notch, topLeft: small, bottomRight: small)
        : RRect.fromRectAndCorners(rect,
            bottomRight: outer, topLeft: notch, topRight: small, bottomLeft: small);

    // Metal, tuned to the chassis' dark lower body so it reads as the same case.
    canvas.drawRRect(
      pod,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [p.m2, p.m3],
        ).createShader(rect),
    );
    // A hairline highlight along the top edge — the moulded bevel.
    canvas.drawRRect(
      pod.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = p.mh.withValues(alpha: 0.5),
    );

    // The woofer.
    final c = size.center(Offset.zero);
    final r = math.min(size.width, size.height) / 2 - 6;

    // The basket: a recessed ring (the fixed housing).
    canvas.drawCircle(c, r, Paint()..color = p.mv1);
    canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = p.mh);

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
      old.level != level || old.left != left || old.p != p;
}
