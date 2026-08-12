// The music player deck: now-playing title, a draggable seek bar, shuffle/repeat,
// a tracklist, play/pause + skip, and a real spectrum visualizer. Every control
// drives real playback (media_kit); the visualizer reads the current track's
// analysed spectrogram off the live play head (see MusicController) and never
// affects playback.

import 'dart:typed_data';

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:provider/provider.dart';

import '../../design/text.dart';
import '../../design/tokens.dart';
import '../../state/music.dart';
import '../../state/settings.dart';
import 'marquee.dart';

class MusicPlayerPanel extends StatelessWidget {
  final Palette palette;

  /// Draw the screensaver's stripped-back copy: the title (still, not scrolling),
  /// the visualizer, the transport and the progress bar — and nothing else.
  ///
  /// This is the SAME layout, with the omitted parts kept as empty space rather
  /// than removed. That is the point: if the copy rebuilt the column with fewer
  /// children, everything below a hidden one would shift up and the buttons would
  /// no longer line up with where they sit normally. One layout, some of it not
  /// painted, so the two cannot drift apart.
  final bool saver;

  const MusicPlayerPanel(
      {super.key, required this.palette, this.saver = false});

  /// Keep [child]'s space but don't paint it, when this is the saver copy.
  Widget _keepSpace(Widget child) => saver
      ? Visibility(
          visible: false,
          maintainSize: true,
          maintainAnimation: true,
          maintainState: true,
          child: child,
        )
      : child;

  String _fmt(Duration d) {
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final m = context.watch<MusicController>();
    final settings = context.watch<SettingsController>();
    final egg = settings.nostalgia && settings.demoMode2000s;
    final canBuiltIn = egg && m.hasTracks;

    if (!m.deckOpen) {
      // Idle — a slim one-line bar, not the full deck, so it doesn't eat the
      // tube when nothing's playing. With Nostalgia on it can start/list the
      // built-in soundtrack; with it off it just rests (trove playback starts
      // from a file row). The full deck only unfolds while something plays.
      // While a tapped trove track is being fetched, this bar shows a spinner so
      // the tap has visible feedback before the deck appears.
      final loading = m.loadingTrove;
      final folded = m.active;

      // Folded with a track loaded: the visualizer, the name, and one target —
      // a tap anywhere unfolds it. No transport buttons, because a button here
      // would be a piece of the bar that does NOT unfold it.
      if (folded) {
        return _wheel(
          m,
          GestureDetector(
            onTap: m.expandDeck,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              child: Row(
                children: [
                  SizedBox(
                    width: 62,
                    height: 22,
                    child: _Visualizer(palette: p, music: m),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      loading
                          ? 'LOADING…'
                          : (m.notice ?? (m.title.isEmpty ? '—' : m.title)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: glass(
                          15, m.notice != null ? p.a : (m.playing ? p.soft : p.foot)),
                    ),
                  ),
                  if (loading) ...[const SizedBox(width: 8), _spinner(p)],
                ],
              ),
            ),
          ),
        );
      }

      // Nothing loaded at all. There is no deck to unfold, so this bar keeps its
      // transport: with the soundtrack available it can start it, otherwise it
      // just rests and trove playback starts from a file row.
      return _wheel(
        m,
        Row(
          children: [
            loading
                ? _spinner(p)
                : GestureDetector(
                    onTap: canBuiltIn ? () => m.toggle() : null,
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(Icons.play_arrow,
                          size: 26, color: canBuiltIn ? p.a : p.foot),
                    ),
                  ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                  loading ? 'LOADING…' : (m.notice ?? '—'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // A file that can't be decoded says so here. Otherwise a tap on
                  // one looked exactly like a tap on nothing.
                  style: glass(15,
                      m.notice != null ? p.a : (loading ? p.mid : p.foot))),
            ),
            if (canBuiltIn && !loading) ...[
              const SizedBox(width: 8),
              _volumeControl(p, m),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => _showTracklist(context, m, p),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(Icons.queue_music, color: p.mid, size: 20),
                ),
              ),
            ],
          ],
        ),
      );
    }

    // A trove folder IS a playlist, so it gets the full transport — shuffle, prev,
    // next and repeat all act on that folder and nothing outside it. The built-in
    // soundtrack still needs Nostalgia on to show its own.
    final playlist = m.isStream ? m.count > 1 : egg;

    final total = m.duration.inMilliseconds;
    final frac =
        total > 0 ? (m.position.inMilliseconds / total).clamp(0.0, 1.0) : 0.0;

    return _wheel(
      m,
      Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Now playing — marquee title, tracklist button, index.
        Row(
          children: [
            // The note folds the deck. It is the only thing that does, so a tap
            // anywhere else on the open deck still belongs to the control under
            // it. Sized to the title's line height so adding the target moved
            // nothing.
            _keepSpace(GestureDetector(
              onTap: m.minimizeDeck,
              behavior: HitTestBehavior.opaque,
              child: SizedBox(
                width: 30,
                height: 22,
                child: Center(child: Text('♪', style: glass(16, p.a))),
              ),
            )),
            // A spinner while the current track is opening or buffering, so any
            if (m.loadingTrove) ...[
              _keepSpace(_spinner(p)),
              const SizedBox(width: 6),
            ],
            Expanded(
              // On the saver the title isn't here at all — a one-line strip with a
              // scrolling name is the wrong shape for a sleeping screen, and
              // squeezing a long title into it can only ellipsise or crawl. The
              // saver draws the whole title as its own centred, wrapping block
              // above the controls (see SaverLayer). The box stays so the
              // visualizer, bar and buttons below don't move.
              child: _keepSpace(SizedBox(
                height: 22,
                child: Marquee(text: m.title, style: glass(17, p.bright)),
              )),
            ),
            if (egg || m.isStream) ...[
              const SizedBox(width: 8),
              _keepSpace(GestureDetector(
                onTap: () => _showTracklist(context, m, p),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(Icons.queue_music, color: p.mid, size: 20),
                ),
              )),
            ],
            const SizedBox(width: 8),
            // A folder still says TROVE, but now carries its position in it too.
            _keepSpace(Text(
                m.isStream
                    ? 'TROVE ${m.index + 1}/${m.count}'
                    : '${m.index + 1}/${m.count}',
                style: mono(11, p.mid))),
          ],
        ),
        if (m.notice != null && !saver)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(m.notice!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: glass(13, p.a)),
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
              // 14 was thinner than a fingertip for a control you DRAG, which
              // needs more slop than one you tap. The painter centres itself, so
              // the extra height is invisible.
              height: 24,
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
            _keepSpace(Text(_fmt(m.position), style: mono(10, p.foot))),
            _keepSpace(_volumeControl(p, m)),
            _keepSpace(Text(_fmt(m.duration), style: mono(10, p.foot))),
          ],
        ),
        const SizedBox(height: 6),
        // Transport. shuffle · prev · next · repeat whenever there's a list to
        // move through — a trove folder or the built-in soundtrack; a lone track
        // gets just play/pause.
        Row(
          mainAxisAlignment: playlist
              ? MainAxisAlignment.spaceEvenly
              : MainAxisAlignment.center,
          children: [
            if (playlist)
              _keepSpace(
                  _iconToggle(p, Icons.shuffle, m.shuffle, m.toggleShuffle)),
            if (playlist) _btn(p, Icons.skip_previous, m.prev),
            _btn(p, m.playing ? Icons.pause : Icons.play_arrow, m.toggle,
                big: true),
            if (playlist) _btn(p, Icons.skip_next, m.next),
            if (playlist)
              _keepSpace(_iconToggle(
                  p,
                  m.repeat == MusicRepeat.one ? Icons.repeat_one : Icons.repeat,
                  m.repeat != MusicRepeat.off,
                  m.cycleRepeat)),
          ],
        ),
      ],
      ),
    );
  }

  /// Scroll the wheel anywhere over the deck to nudge the volume — up is louder.
  /// A wheel signal isn't a drag, so it never disturbs the seek bar.
  ///
  /// opaque, NOT the default deferToChild: the deck is mostly gaps between the
  /// controls, and deferToChild only catches the wheel directly over a painted
  /// widget — so scrolling in the empty space did nothing. opaque claims the
  /// whole panel rectangle, so a scroll ANYWHERE over it counts.
  Widget _wheel(MusicController m, Widget child) => Listener(
        behavior: HitTestBehavior.opaque,
        onPointerSignal: (sig) {
          if (sig is PointerScrollEvent) {
            m.nudgeVolume(sig.scrollDelta.dy < 0 ? 0.05 : -0.05);
          }
        },
        child: child,
      );

  /// A small spinner — plain loading feedback while a trove track is fetched.
  Widget _spinner(Palette p) => SizedBox(
        width: 13,
        height: 13,
        child: CircularProgressIndicator(
          strokeWidth: 1.6,
          valueColor: AlwaysStoppedAnimation<Color>(p.a),
        ),
      );

  /// Speaker + a short level bar: live feedback for the wheel, and a tap-target
  /// (mute / unmute) that will also carry the volume on touch later.
  Widget _volumeControl(Palette p, MusicController m) {
    final icon = m.muted
        ? Icons.volume_off
        : m.volume < 0.5
            ? Icons.volume_down
            : Icons.volume_up;
    return GestureDetector(
      onTap: () => m.toggleMute(),
      behavior: HitTestBehavior.opaque,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: m.muted ? p.foot : p.mid),
          const SizedBox(width: 5),
          Container(
            width: 44,
            height: 6,
            decoration: BoxDecoration(
              color: p.dim,
              borderRadius: BorderRadius.circular(2),
            ),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: m.volume.clamp(0.0, 1.0),
              child: Container(
                decoration: BoxDecoration(
                  color: p.a,
                  borderRadius: BorderRadius.circular(2),
                  boxShadow: [BoxShadow(color: p.aAlpha(0.5), blurRadius: 4)],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _iconToggle(
          Palette p, IconData icon, bool active, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: active
                ? BoxDecoration(
                    shape: BoxShape.circle,
                    color: p.aAlpha(0.22),
                    border: Border.all(color: p.a, width: 1.4),
                    boxShadow: [
                      BoxShadow(color: p.aAlpha(0.45), blurRadius: 9),
                    ],
                  )
                : null,
            child: Icon(icon, color: active ? p.bright : p.soft, size: 22),
          ),
        ),
      );

  Widget _btn(Palette p, IconData icon, VoidCallback onTap, {bool big = false}) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: EdgeInsets.all(big ? 11 : 9),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: p.a.withValues(alpha: 0.6)),
          boxShadow:
              big ? [BoxShadow(color: p.aAlpha(0.25), blurRadius: 10)] : null,
        ),
        child: Icon(icon, color: p.a, size: big ? 30 : 22),
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
                        m.playAt(i);
                        Navigator.of(ctx).pop();
                      },
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 11),
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
