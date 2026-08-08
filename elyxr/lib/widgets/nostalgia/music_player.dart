// The music player deck: now-playing title, a draggable seek bar, shuffle/repeat,
// a tracklist, and play/pause + skip. Every control drives real playback
// (audioplayers). No visualizer here — playback is the point, and a real
// spectrum needs to tap the actual audio output, which is a separate concern
// deliberately kept off the player's critical path.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

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

    if (!m.hasTracks && !m.active) {
      // Idle — the deck is always present; it just has nothing loaded yet.
      return Row(children: [
        Text('♪ ', style: glass(16, p.foot)),
        Text('—', style: glass(15, p.foot)),
      ]);
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
        // Real spectrum — FFT of the system's actual audio output (captured from
        // the monitor source), so it reacts to whatever is truly coming out. It
        // sits on top of the player and never affects playback.
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

/// A real spectrum: captures the system's audio OUTPUT (the monitor source) and
/// runs an FFT over it every frame, so the bars react to what's actually coming
/// out of the speakers — decoupled from the player entirely. If output capture
/// isn't available it simply draws nothing; it never fakes motion and never
/// affects playback.
class _Visualizer extends StatefulWidget {
  final Palette palette;
  const _Visualizer({required this.palette});

  @override
  State<_Visualizer> createState() => _VisualizerState();
}

class _VisualizerState extends State<_Visualizer> {
  static const int _fftSize = 1024; // power of two
  static const int _bars = 28;

  final AudioRecorder _rec = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  final Float64List _ring = Float64List(_fftSize);
  int _written = 0;
  Timer? _timer;

  final ValueNotifier<List<double>> _levels =
      ValueNotifier<List<double>>(List<double>.filled(_bars, 0.0));

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      if (!await _rec.hasPermission()) return;
      // Pick the OUTPUT monitor so we visualise what's playing, not the mic. If
      // there's no monitor device, don't capture at all (nothing, never the mic).
      InputDevice? monitor;
      try {
        for (final d in await _rec.listInputDevices()) {
          if (d.label.toLowerCase().contains('monitor')) {
            monitor = d;
            break;
          }
        }
      } catch (_) {}
      if (monitor == null) return;
      final stream = await _rec.startStream(RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 44100,
        numChannels: 1,
        device: monitor,
      ));
      _sub = stream.listen(_onBytes, onError: (_) {});
      _timer =
          Timer.periodic(const Duration(milliseconds: 33), (_) => _compute());
    } catch (_) {
      // No capture available — the bars stay flat (honest), player unaffected.
    }
  }

  void _onBytes(Uint8List bytes) {
    final bd = ByteData.sublistView(bytes);
    final n = bytes.length ~/ 2;
    for (var i = 0; i < n; i++) {
      _ring[_written % _fftSize] = bd.getInt16(i * 2, Endian.little) / 32768.0;
      _written++;
    }
  }

  void _compute() {
    if (_written < _fftSize) return;
    final re = Float64List(_fftSize);
    final im = Float64List(_fftSize);
    final start = _written % _fftSize;
    for (var i = 0; i < _fftSize; i++) {
      final s = _ring[(start + i) % _fftSize];
      // Hann window to tame spectral leakage.
      final w = 0.5 - 0.5 * math.cos(2 * math.pi * i / (_fftSize - 1));
      re[i] = s * w;
    }
    _fft(re, im);
    final half = _fftSize ~/ 2;
    final mag = Float64List(half);
    for (var i = 0; i < half; i++) {
      mag[i] = math.sqrt(re[i] * re[i] + im[i] * im[i]);
    }
    final prev = _levels.value;
    final out = List<double>.filled(_bars, 0.0);
    const int loBin = 2, hiBin = 400; // ~85Hz .. ~17kHz across the bars
    for (var b = 0; b < _bars; b++) {
      final lo = (loBin * math.pow(hiBin / loBin, b / _bars)).floor();
      final hi = (loBin * math.pow(hiBin / loBin, (b + 1) / _bars))
          .ceil()
          .clamp(lo + 1, half);
      var peak = 0.0;
      for (var k = lo; k < hi; k++) {
        if (mag[k] > peak) peak = mag[k];
      }
      // Scale + curve. The divisor sets sensitivity (may want tuning on real
      // audio); sqrt lifts quiet detail.
      var v = math.sqrt((peak / 30.0).clamp(0.0, 1.0));
      // Fast attack, slow decay so it dances rather than flickers.
      final p = prev[b];
      v = v > p ? v : p * 0.82 + v * 0.18;
      out[b] = v.clamp(0.0, 1.0);
    }
    _levels.value = out;
  }

  // In-place iterative radix-2 Cooley–Tukey FFT. Lengths are a power of two.
  static void _fft(Float64List re, Float64List im) {
    final n = re.length;
    for (var i = 1, j = 0; i < n; i++) {
      var bit = n >> 1;
      for (; (j & bit) != 0; bit >>= 1) {
        j ^= bit;
      }
      j ^= bit;
      if (i < j) {
        var t = re[i];
        re[i] = re[j];
        re[j] = t;
        t = im[i];
        im[i] = im[j];
        im[j] = t;
      }
    }
    for (var len = 2; len <= n; len <<= 1) {
      final ang = -2 * math.pi / len;
      final wlenR = math.cos(ang), wlenI = math.sin(ang);
      final half = len >> 1;
      for (var i = 0; i < n; i += len) {
        var wR = 1.0, wI = 0.0;
        for (var k = 0; k < half; k++) {
          final aR = re[i + k], aI = im[i + k];
          final bR = re[i + k + half] * wR - im[i + k + half] * wI;
          final bI = re[i + k + half] * wI + im[i + k + half] * wR;
          re[i + k] = aR + bR;
          im[i + k] = aI + bI;
          re[i + k + half] = aR - bR;
          im[i + k + half] = aI - bI;
          final nwR = wR * wlenR - wI * wlenI;
          wI = wR * wlenI + wI * wlenR;
          wR = nwR;
        }
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    _rec.stop();
    _rec.dispose();
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
