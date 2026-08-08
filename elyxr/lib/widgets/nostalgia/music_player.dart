// The music player deck: now-playing title, a draggable seek bar, shuffle/repeat,
// a tracklist, play/pause + skip, and a real spectrum visualizer. Every control
// drives real playback (audioplayers); the visualizer reads the current track's
// analysed spectrogram off the live play head (see MusicController) and never
// affects playback.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
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

    if (!m.active) {
      // Idle — a slim one-line bar, not the full deck, so it doesn't eat the
      // tube when nothing's playing. Still present and startable: a play button
      // and the tracklist. The full deck only unfolds while something plays.
      return Row(
        children: [
          GestureDetector(
            onTap: m.hasTracks ? () => m.toggle() : null,
            behavior: HitTestBehavior.opaque,
            child: Icon(Icons.play_arrow,
                size: 20, color: m.hasTracks ? p.a : p.foot),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(m.hasTracks ? m.title : '—',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: glass(15, p.foot)),
          ),
          if (m.hasTracks) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => _showTracklist(context, m, p),
              behavior: HitTestBehavior.opaque,
              child: Icon(Icons.queue_music, color: p.mid, size: 18),
            ),
          ],
        ],
      );
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
            Text(m.isStream ? 'TROVE' : '${m.index + 1}/${m.count}',
                style: mono(11, p.mid)),
          ],
        ),
        const SizedBox(height: 6),
        // Real spectrum — the actual audio of the current track, analysed into a
        // spectrogram and read straight off the live play head. It's the true
        // FFT of the true audio shown at the exact playback instant, so it locks
        // to the beat with no capture lag. Sits on top; never affects playback.
        SizedBox(height: 26, child: _Visualizer(palette: p, music: m)),
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

/// A real spectrum: the current track's own audio, analysed into a spectrogram
/// (see MusicController) and sampled off the live play head every screen frame.
/// It's the true FFT of the true audio shown at the exact playback instant — no
/// capture pipeline, so it can't lag the beat. When nothing is playing (or the
/// spectrogram isn't ready yet) the bars rest at zero; it never fakes motion and
/// never affects playback.
class _Visualizer extends StatefulWidget {
  final Palette palette;
  final MusicController music;
  const _Visualizer({required this.palette, required this.music});

  @override
  State<_Visualizer> createState() => _VisualizerState();
}

class _VisualizerState extends State<_Visualizer>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  // Smoothed display levels — instant attack, quick decay, so the bars punch on
  // transients and fall back fast rather than snapping or drifting.
  final Float64List _display = Float64List(MusicController.kVisBars);
  final ValueNotifier<List<double>> _levels = ValueNotifier<List<double>>(
      List<double>.filled(MusicController.kVisBars, 0.0));

  @override
  void initState() {
    super.initState();
    // A ticker fires once per frame (vsync), so the bars refresh as fast as the
    // display and stay locked to the play position.
    _ticker = createTicker(_tick)..start();
  }

  void _tick(Duration _) {
    final m = widget.music;
    // Only animate to live data while actually playing; paused/idle rests to 0.
    final src = m.playing ? m.visualizerBars() : const <double>[];
    final out = List<double>.filled(MusicController.kVisBars, 0.0);
    var changed = false;
    for (var b = 0; b < MusicController.kVisBars; b++) {
      final target = b < src.length ? src[b] : 0.0;
      final cur = _display[b];
      final next = target > cur ? target : cur * 0.62 + target * 0.38;
      if ((next - cur).abs() > 0.001) changed = true;
      _display[b] = next;
      out[b] = next;
    }
    if (changed) _levels.value = out;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _levels.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<List<double>>(
        valueListenable: _levels,
        builder: (_, levels, __) => CustomPaint(
          size: Size.infinite,
          painter: _BarsPainter(levels, widget.palette.a),
        ),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  final List<double> levels;
  final Color a;
  _BarsPainter(this.levels, this.a);

  @override
  void paint(Canvas canvas, Size size) {
    final bw = size.width / levels.length;
    final paint = Paint()..color = a.withValues(alpha: 0.9);
    for (var i = 0; i < levels.length; i++) {
      final h = (size.height * levels[i]).clamp(0.0, size.height);
      if (h <= 0.5) continue;
      canvas.drawRect(
        Rect.fromLTWH(i * bw + bw * 0.18, size.height - h, bw * 0.64, h),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BarsPainter old) => true;
}
