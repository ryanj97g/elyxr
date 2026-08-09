// A music-reactive glow around the inside edge of the tube — the curved-phone
// "edge lighting" look, but for fun. It's driven by the same live spectrum the
// visualizer and woofers read (MusicController.visualizerBars, off the play
// head): the whole edge strobes on the beat — snap bright on the hit, fall fast
// — rather than a bright spot travelling around. When nothing's playing it fades
// to nothing and stops repainting.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:provider/provider.dart';

import '../design/tokens.dart';
import '../state/music.dart';

class EdgeLight extends StatefulWidget {
  final Palette palette;
  const EdgeLight({super.key, required this.palette});

  @override
  State<EdgeLight> createState() => _EdgeLightState();
}

class _EdgeLightState extends State<EdgeLight>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  // A strobe level (bass, instant attack + fast decay) and an overall energy
  // envelope (is anything playing at all).
  double _flash = 0;
  double _energy = 0;
  // Bumped only while there's something to show, so a resting tube isn't
  // repainting every frame for nothing.
  final _rev = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick)..start();
  }

  void _tick(Duration _) {
    final m = context.read<MusicController>();
    final bars = m.playing ? m.visualizerBars() : const <double>[];
    var bass = 0.0;
    var sum = 0.0;
    if (bars.isNotEmpty) {
      final n = math.min(4, bars.length); // the low bands carry the beat
      for (var i = 0; i < n; i++) {
        bass += bars[i];
      }
      bass /= n;
      for (final b in bars) {
        sum += b;
      }
    }
    bass = (bass * 1.6).clamp(0.0, 1.0);
    // Strobe: snap to the hit, then fall fast so each beat reads as a flash.
    _flash = bass > _flash ? bass : _flash * 0.70;
    final avg = bars.isEmpty ? 0.0 : sum / bars.length;
    _energy = avg > _energy ? avg : _energy * 0.86 + avg * 0.14;
    if (_flash > 0.002 || _energy > 0.002) _rev.value++;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _rev.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: ValueListenableBuilder<int>(
          valueListenable: _rev,
          builder: (_, __, ___) => CustomPaint(
            size: Size.infinite,
            painter: _EdgeLightPainter(widget.palette, _flash, _energy),
          ),
        ),
      ),
    );
  }
}

class _EdgeLightPainter extends CustomPainter {
  final Palette p;
  final double flash; // 0..1 beat strobe
  final double energy; // 0..1 overall envelope
  const _EdgeLightPainter(this.p, this.flash, this.energy);

  @override
  void paint(Canvas canvas, Size size) {
    // Only alive while music plays; a faint baseline so the edge is present
    // between beats, then the strobe drives it hard on each hit.
    final fade = (energy * 4.0).clamp(0.0, 1.0);
    final hit = flash.clamp(0.0, 1.0);
    final show = ((0.14 + 0.86 * hit) * fade).clamp(0.0, 1.0);
    if (show <= 0.01) return;

    // The ring hugs just inside the tube's rounded content edge (radius 12).
    final rect = (Offset.zero & size).deflate(2);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(11));

    // Uniform accent all the way round, lifting toward the bright phosphor on
    // the hardest hits for a white-hot flash.
    final col = Color.lerp(p.a, p.bright, (hit * 0.7).clamp(0.0, 1.0))!;

    // A wide blurred pass for the bloom that spills onto the glass, then a crisp
    // brighter line right on the edge. Both flash together.
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5 + 20 * hit
        ..color = col.withValues(alpha: (show * 0.9).clamp(0.0, 1.0))
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 5 + 22 * hit),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 + 3 * hit
        ..color = col.withValues(alpha: show),
    );
  }

  @override
  bool shouldRepaint(covariant _EdgeLightPainter old) =>
      old.flash != flash || old.energy != energy || old.p != p;
}
