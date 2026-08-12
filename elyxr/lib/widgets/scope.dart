
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

  final List<double> wave;
  const _ScopePainter(this.p, this.wave);

  @override
  void paint(Canvas canvas, Size size) => paintScope(canvas, size, p, wave);

  @override
  bool shouldRepaint(covariant _ScopePainter old) =>
      old.wave != wave || old.p != p;
}

void paintScope(Canvas canvas, Size size, Palette p, List<double> wave) {
  final band = scopeBand(size.width, size.height);
  if (band.width < 24 || band.height < 8) return; // no room to draw in
  final mid = band.center.dy;
  final cx = band.center.dx;
  final amp = band.height / 2 - 2;

  canvas.drawLine(
    Offset(band.left, mid),
    Offset(band.right, mid),
    Paint()
      ..color = p.aAlpha(0.22)
      ..strokeWidth = 1,
  );
  if (wave.length < 2) return;

  // Each trace spans the whole band, not half of it, and runs inward from its own
  // outer edge: sample 0 at the edge, the tail at the far side. Drawn twice, the
  // second mirrored, so the pair is symmetric about the midpoint between the
  // speakers while neither line is cut short — they cross in the middle. The
  // cradles are the cutoff, so there is no fade.
  final path = Path();
  final step = band.width / (wave.length - 1);
  for (var i = 0; i < wave.length; i++) {
    final x = band.right - i * step;
    final y = mid - wave[i] * amp;
    if (i == 0) {
      path.moveTo(x, y);
    } else {
      path.lineTo(x, y);
    }
  }

  final line = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.4
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..color = p.a;

  for (final flip in const [false, true]) {
    canvas.save();
    if (flip) {
      canvas.translate(2 * cx, 0);
      canvas.scale(-1, 1);
    }
    canvas.drawPath(path, line);
    canvas.restore();
  }
}
