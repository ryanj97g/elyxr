// The oscilloscope built into the bottom of the chassis: the real waveform of
// whatever is playing, drawn in the strip of glass between the two speaker
// cradles.
//
// That strip exists because the tube's content has to stop clear of the cradles
// (Tube.contentBottomInset) so nothing is laid out under metal. It runs the full
// width between the domes and was otherwise empty. Its shape decides the form —
// a scope is native to a letterbox, which almost nothing else is.
//
// Mirrored about the midpoint between the speakers: time runs outward from the
// centre in both directions, so the left half is the right half flipped. Both
// halves therefore show the SAME waveform — this buys symmetry against the two
// drivers at the ends, not a wider window. Drawn as one path under one flipped
// transform, so the two halves can't disagree.
//
// It's a chassis element, not part of the music screen: it shows on every screen,
// and it flat-lines rather than vanishing when there's nothing playing, because a
// meter that disappears stops reading as part of the hardware. It sits above the
// screensaver for the same reason — the case's own instrument shouldn't switch off
// because the screen went idle.

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:provider/provider.dart';

import '../design/tokens.dart';
import '../state/music.dart';

class ChassisScope extends StatefulWidget {
  final Palette palette;
  const ChassisScope({super.key, required this.palette});

  @override
  State<ChassisScope> createState() => _ChassisScopeState();
}

class _ChassisScopeState extends State<ChassisScope>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<int> _rev = ValueNotifier<int>(0);
  List<double> _wave = const <double>[];
  // Whether the last painted frame was the resting flat line. Tracked so the
  // transition INTO rest still gets painted once — stopping a frame early would
  // leave the last live trace frozen on the glass after the music stopped.
  bool _resting = true;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick)..start();
  }

  void _tick(Duration _) {
    final m = context.read<MusicController>();
    final wave = m.playing ? m.visualizerWave() : const <double>[];
    final resting = wave.isEmpty;
    if (resting && _resting) return; // nothing moving; stop repainting
    _resting = resting;
    _wave = wave;
    _rev.value++;
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
            painter: _ScopePainter(widget.palette, _wave),
          ),
        ),
      ),
    );
  }
}

class _ScopePainter extends CustomPainter {
  final Palette p;

  /// The trace in -1..1, or empty for the resting line.
  final List<double> wave;
  const _ScopePainter(this.p, this.wave);

  @override
  void paint(Canvas canvas, Size size) => paintScope(canvas, size, p, wave);

  @override
  bool shouldRepaint(covariant _ScopePainter old) =>
      old.wave != wave || old.p != p;
}

/// Draw the scope into the bottom band of a tube of [size]. Top-level so it can
/// be rasterised and measured on its own: what's worth checking is that the two
/// halves really are mirror images and that it stays down in its band, and
/// neither is worth standing up a player and a provider to ask.
void paintScope(Canvas canvas, Size size, Palette p, List<double> wave) {
  final band = scopeBand(size.width, size.height);
  if (band.width < 24 || band.height < 8) return; // no room to draw in
  final mid = band.center.dy;
  final cx = band.center.dx;
  final half = band.width / 2;
  final amp = band.height / 2 - 2;

  // The resting line: always present, so the instrument reads as switched on with
  // nothing to show rather than as absent.
  canvas.drawLine(
    Offset(band.left, mid),
    Offset(band.right, mid),
    Paint()
      ..color = p.aAlpha(0.22)
      ..strokeWidth = 1,
  );
  if (wave.length < 2) return;

  // One half of the trace, running from the centre outward. The flipped copy
  // below turns that into the other half.
  final path = Path();
  final step = half / (wave.length - 1);
  for (var i = 0; i < wave.length; i++) {
    final x = cx + i * step;
    final y = mid - wave[i] * amp;
    if (i == 0) {
      path.moveTo(x, y);
    } else {
      path.lineTo(x, y);
    }
  }

  // Fade the outer end out, so the trace stops where the cradle begins instead of
  // ending in a bright vertical cut that reads as a clipping fault. Resolved in
  // the canvas's local space, so the flipped pass gets a mirrored fade for free.
  final shader = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [p.a, p.a, p.a.withValues(alpha: 0)],
    stops: const [0.0, 0.78, 1.0],
  ).createShader(Rect.fromLTRB(cx, band.top, band.right, band.bottom));

  // A blurred pass for the phosphor bloom, then the trace itself over it — the
  // same two-pass treatment the edge light uses, so both read as the same glass.
  final bloom = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 3
    ..strokeCap = StrokeCap.round
    ..shader = shader
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
  final line = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.4
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..shader = shader;

  for (final flip in const [false, true]) {
    canvas.save();
    if (flip) {
      // x → 2·cx − x: a mirror about the midpoint between the two speakers.
      canvas.translate(2 * cx, 0);
      canvas.scale(-1, 1);
    }
    canvas.drawPath(path, bloom);
    canvas.drawPath(path, line);
    canvas.restore();
  }
}
