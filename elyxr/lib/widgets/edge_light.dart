// A music-reactive glow that runs around the inside edge of the tube — the
// curved-phone "edge lighting" look, but for fun. It's driven by the same live
// spectrum the visualizer and woofers read (MusicController.visualizerBars, off
// the play head), so bright arcs chase around the border in time with the track.
// When nothing's playing it fades to nothing and stops repainting.

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
  // Smoothed per-band levels, an overall energy envelope, and a slowly turning
  // phase so the lit arcs travel around the ring instead of sitting still.
  List<double> _smooth = List<double>.filled(MusicController.kVisBars, 0);
  double _energy = 0;
  double _phase = 0;
  // Bumped only while there's something to show, so a resting tube isn't
  // repainting every frame for nothing.
  final _rev = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick)..start();
  }

  void _tick(Duration elapsed) {
    _phase = elapsed.inMicroseconds / 1000000.0;
    final m = context.read<MusicController>();
    final bars = m.playing ? m.visualizerBars() : const <double>[];
    var sum = 0.0;
    for (var i = 0; i < _smooth.length; i++) {
      final target = i < bars.length ? bars[i] : 0.0;
      // Snap up instantly, ease down — the lit edge tracks the beat but trails
      // off smoothly rather than flickering.
      _smooth[i] =
          target > _smooth[i] ? target : _smooth[i] * 0.80 + target * 0.20;
      sum += _smooth[i];
    }
    final avg = _smooth.isEmpty ? 0.0 : sum / _smooth.length;
    _energy = avg > _energy ? avg : _energy * 0.86 + avg * 0.14;
    // Only drive repaints while the ring is (or is still fading) visible.
    if (_energy > 0.002) _rev.value++;
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
            painter: _EdgeLightPainter(
                widget.palette, List<double>.of(_smooth), _energy, _phase),
          ),
        ),
      ),
    );
  }
}

class _EdgeLightPainter extends CustomPainter {
  final Palette p;
  final List<double> bars; // smoothed band levels, 0..1
  final double energy; // overall envelope, 0..1
  final double phase; // seconds, drives the travelling arcs
  const _EdgeLightPainter(this.p, this.bars, this.energy, this.phase);

  @override
  void paint(Canvas canvas, Size size) {
    // Master fade: silent → nothing, so it only lives while music plays. Boosted
    // so ordinary music lights it well before it needs to be blaring.
    final fade = (energy * 4.2).clamp(0.0, 1.0);
    if (fade <= 0.01 || bars.isEmpty) return;

    // The ring hugs just inside the tube's rounded content edge (radius 12).
    final rect = (Offset.zero & size).deflate(2);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(11));

    // Build the colour ring: sample the spectrum around the perimeter with a
    // slow rotation so bright arcs chase around. Each stop's alpha is its band
    // level; the hottest hits lift toward the bright phosphor for a white-hot
    // core. First and last stop match so the sweep closes seamlessly.
    const n = 60;
    final nb = bars.length;
    final colors = <Color>[];
    final stops = <double>[];
    for (var j = 0; j <= n; j++) {
      final t = j / n;
      final fpos = t * nb + phase * 6.0; // ~6 bands/sec of travel
      final i0 = fpos.floor();
      final frac = fpos - i0;
      final a0 = bars[((i0 % nb) + nb) % nb];
      final a1 = bars[(((i0 + 1) % nb) + nb) % nb];
      final level = (a0 + (a1 - a0) * frac).clamp(0.0, 1.0);
      final col = Color.lerp(p.a, p.bright, (level * 0.6).clamp(0.0, 1.0))!;
      final alpha = ((0.10 + 0.90 * level) * fade).clamp(0.0, 1.0);
      colors.add(col.withValues(alpha: alpha));
      stops.add(t);
    }

    final shader = SweepGradient(
      colors: colors,
      stops: stops,
      transform: const GradientRotation(-math.pi / 2), // start at the top
    ).createShader(rect);

    // A wide blurred pass for the bloom that spills onto the glass, then a crisp
    // brighter line right on the edge. Both ride the same rotating spectrum.
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6 + 14 * energy
        ..shader = shader
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 6 + 16 * energy),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 + 2.5 * energy
        ..shader = shader,
    );
  }

  @override
  bool shouldRepaint(covariant _EdgeLightPainter old) =>
      old.phase != phase || old.energy != energy || old.p != p;
}
