// The Nostalgia Mode music player — a keygen-style deck: now-playing title, a
// draggable seek bar, shuffle/repeat, a tracklist, and play/pause + skip. Every
// element reflects real playback state (no decorative fakery). Reads whatever's
// in assets/music/ (see MusicController).

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:provider/provider.dart';

import '../../design/text.dart';
import '../../design/tokens.dart';
import '../../state/music.dart';
import 'marquee.dart';

class MusicPlayerPanel extends StatelessWidget {
  final Palette palette;
  const MusicPlayerPanel({super.key, required this.palette});

  String _fmt(Duration d) {
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final m = context.watch<MusicController>();

    if (!m.hasTracks) {
      return Text('Drop tracks in assets/music/ to fill the deck.',
          style: glass(15, p.foot));
    }

    final total = m.duration.inMilliseconds;
    final frac =
        total > 0 ? (m.position.inMilliseconds / total).clamp(0.0, 1.0) : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Now playing — marquee title, tracklist button, index.
        Row(
          children: [
            Text('♪ ', style: glass(16, p.a)),
            Expanded(
              child: SizedBox(
                height: 22,
                child: Marquee(text: m.title, style: glass(17, p.bright)),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => _showTracklist(context, m, p),
              behavior: HitTestBehavior.opaque,
              child: Icon(Icons.queue_music, color: p.mid, size: 18),
            ),
            const SizedBox(width: 8),
            Text('${m.index + 1}/${m.count}', style: mono(11, p.mid)),
          ],
        ),
        const SizedBox(height: 6),
        // Real spectrum — live FFT off the audio engine.
        SizedBox(height: 26, child: _Visualizer(palette: p)),
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
        const SizedBox(height: 6),
        // Transport — shuffle · prev · play/pause · next · repeat.
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _iconToggle(p, Icons.shuffle, m.shuffle, m.toggleShuffle),
            _btn(p, Icons.skip_previous, m.prev),
            _btn(p, m.playing ? Icons.pause : Icons.play_arrow, m.toggle,
                big: true),
            _btn(p, Icons.skip_next, m.next),
            _iconToggle(
                p,
                m.repeat == MusicRepeat.one ? Icons.repeat_one : Icons.repeat,
                m.repeat != MusicRepeat.off,
                m.cycleRepeat),
          ],
        ),
      ],
    );
  }

  Widget _iconToggle(
          Palette p, IconData icon, bool active, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, color: active ? p.a : p.foot, size: 18),
        ),
      );

  Widget _btn(Palette p, IconData icon, VoidCallback onTap, {bool big = false}) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: EdgeInsets.all(big ? 7 : 5),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: p.a.withValues(alpha: 0.6)),
          boxShadow:
              big ? [BoxShadow(color: p.aAlpha(0.25), blurRadius: 10)] : null,
        ),
        child: Icon(icon, color: p.a, size: big ? 24 : 18),
      ),
    );
  }

  void _showTracklist(BuildContext context, MusicController m, Palette p) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 340, maxHeight: 430),
          decoration: BoxDecoration(
            color: p.tubeBg,
            border: Border.all(color: p.a.withValues(alpha: 0.5)),
            borderRadius: BorderRadius.circular(4),
          ),
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('▸ TRACKS', style: mono(10, p.mid, spacing: 0.16)),
              const SizedBox(height: 8),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: m.count,
                  itemBuilder: (c, i) {
                    final cur = i == m.index;
                    return GestureDetector(
                      onTap: () {
                        m.playIndex(i);
                        Navigator.of(ctx).pop();
                      },
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Row(
                          children: [
                            Text(cur ? '▶ ' : '   ', style: glass(15, p.a)),
                            Expanded(
                              child: Text(m.titleAt(i),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: glass(16, cur ? p.bright : p.soft)),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A live spectrum: reads the audio engine's FFT each frame and draws bars. Real
/// audio data — nothing animates unless sound is actually playing.
class _Visualizer extends StatefulWidget {
  final Palette palette;
  const _Visualizer({required this.palette});

  @override
  State<_Visualizer> createState() => _VisualizerState();
}

class _VisualizerState extends State<_Visualizer>
    with SingleTickerProviderStateMixin {
  AudioData? _audio;
  final ValueNotifier<int> _tick = ValueNotifier(0);
  late final Ticker _ticker;

  @override
  void initState() {
    super.initState();
    try {
      _audio = AudioData(GetSamplesKind.linear);
    } catch (_) {}
    _ticker = createTicker((_) {
      final ad = _audio;
      if (ad != null) {
        try {
          ad.updateSamples();
        } catch (_) {}
      }
      _tick.value++;
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _audio?.dispose();
    _tick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _FftPainter(_audio, _tick, widget.palette.a),
      ),
    );
  }
}

class _FftPainter extends CustomPainter {
  final AudioData? audio;
  final Color a;
  _FftPainter(this.audio, Listenable repaint, this.a) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final ad = audio;
    if (ad == null) return;
    List<double> data;
    try {
      data = ad.getAudioData();
    } catch (_) {
      return;
    }
    if (data.isEmpty) return;
    const bars = 28;
    final bw = size.width / bars;
    final paint = Paint()..color = a.withValues(alpha: 0.9);
    for (var i = 0; i < bars; i++) {
      // The first 256 values are FFT bins; music energy sits in the low-mid, so
      // sample the lower bins (skipping DC).
      final bin = 2 + i * 2;
      final v = (bin < 256 && bin < data.length) ? data[bin].abs() : 0.0;
      final mag = math.sqrt((v * 3.5).clamp(0.0, 1.0));
      final h = (size.height * mag).clamp(1.0, size.height);
      canvas.drawRect(
        Rect.fromLTWH(i * bw + bw * 0.18, size.height - h, bw * 0.64, h),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FftPainter old) => true;
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
