// The Nostalgia Mode music player — a little keygen-style deck: now-playing
// title, an animated equaliser, a draggable seek bar, and play/pause + skip. It
// reads whatever's in assets/music/ (see MusicController).

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../design/text.dart';
import '../../design/tokens.dart';
import '../../state/music.dart';

class MusicPlayerPanel extends StatefulWidget {
  final Palette palette;
  const MusicPlayerPanel({super.key, required this.palette});

  @override
  State<MusicPlayerPanel> createState() => _MusicPlayerPanelState();
}

class _MusicPlayerPanelState extends State<MusicPlayerPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _viz =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))
        ..repeat();

  @override
  void dispose() {
    _viz.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final m = context.watch<MusicController>();

    if (!m.hasTracks) {
      return Text('Drop tracks in assets/music/ to fill the deck.',
          style: glass(15, p.foot));
    }

    final total = m.duration.inMilliseconds;
    final frac = total > 0 ? (m.position.inMilliseconds / total).clamp(0.0, 1.0) : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Now playing.
        Row(
          children: [
            Text('♪ ', style: glass(16, p.a)),
            Expanded(
              child: Text(m.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: glass(17, p.bright)),
            ),
            Text('${m.index + 1}/${m.count}', style: mono(11, p.mid)),
          ],
        ),
        const SizedBox(height: 6),
        // Equaliser — animates while playing, settles when paused.
        SizedBox(
          height: 22,
          child: AnimatedBuilder(
            animation: _viz,
            builder: (context, _) => CustomPaint(
              painter: _EqPainter(_viz.value, m.playing, p.a, p.glow),
              size: Size.infinite,
            ),
          ),
        ),
        const SizedBox(height: 6),
        // Seek bar — tap or drag to scrub.
        LayoutBuilder(builder: (context, c) {
          void seekTo(double dx) {
            if (total <= 0) return;
            final f = (dx / c.maxWidth).clamp(0.0, 1.0);
            m.seek(Duration(milliseconds: (f * total).round()));
          }

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => seekTo(d.localPosition.dx),
            onHorizontalDragUpdate: (d) => seekTo(d.localPosition.dx),
            child: SizedBox(
              height: 14,
              child: CustomPaint(
                painter: _SeekPainter(frac, p.a, p.dim),
                size: Size.infinite,
              ),
            ),
          );
        }),
        const SizedBox(height: 2),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(_fmt(m.position), style: mono(10, p.foot)),
            Text(_fmt(m.duration), style: mono(10, p.foot)),
          ],
        ),
        const SizedBox(height: 4),
        // Transport.
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _btn(p, Icons.skip_previous, m.prev),
            const SizedBox(width: 10),
            _btn(p, m.playing ? Icons.pause : Icons.play_arrow, m.toggle,
                big: true),
            const SizedBox(width: 10),
            _btn(p, Icons.skip_next, m.next),
          ],
        ),
      ],
    );
  }

  Widget _btn(Palette p, IconData icon, VoidCallback onTap, {bool big = false}) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: EdgeInsets.all(big ? 7 : 5),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: p.a.withValues(alpha: 0.6)),
          boxShadow: big ? [BoxShadow(color: p.aAlpha(0.25), blurRadius: 10)] : null,
        ),
        child: Icon(icon, color: p.a, size: big ? 24 : 18),
      ),
    );
  }
}

class _EqPainter extends CustomPainter {
  final double t;
  final bool playing;
  final Color a, glow;
  _EqPainter(this.t, this.playing, this.a, this.glow);

  @override
  void paint(Canvas canvas, Size size) {
    const bars = 24;
    final bw = size.width / bars;
    for (var i = 0; i < bars; i++) {
      final phase = i * 0.6;
      final wave = playing
          ? (0.5 + 0.5 * math.sin(t * 2 * math.pi * 2 + phase)) *
              (0.4 + 0.6 * (0.5 + 0.5 * math.sin(phase * 1.7)))
          : 0.12;
      final h = (size.height * (0.15 + 0.85 * wave)).clamp(2.0, size.height);
      final rect = Rect.fromLTWH(
          i * bw + bw * 0.18, size.height - h, bw * 0.64, h);
      canvas.drawRect(rect, Paint()..color = a.withValues(alpha: 0.85));
    }
  }

  @override
  bool shouldRepaint(covariant _EqPainter old) =>
      old.t != t || old.playing != playing || old.a != a;
}

class _SeekPainter extends CustomPainter {
  final double frac;
  final Color a, track;
  _SeekPainter(this.frac, this.a, this.track);

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final trackPaint = Paint()
      ..color = track
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), trackPaint);
    final fillPaint = Paint()
      ..color = a
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(0, y), Offset(size.width * frac, y), fillPaint);
    // The playhead.
    canvas.drawCircle(
        Offset(size.width * frac, y),
        5,
        Paint()
          ..color = a
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1));
  }

  @override
  bool shouldRepaint(covariant _SeekPainter old) =>
      old.frac != frac || old.a != a;
}
