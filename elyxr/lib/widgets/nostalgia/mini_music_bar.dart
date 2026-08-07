// A compact music bar that rides at the bottom of the tube while a track is
// active, so playback stays visible and controllable outside the Settings deck.
// Shows a thin progress line, play/pause, the scrolling title, and skip.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../design/text.dart';
import '../../design/tokens.dart';
import '../../state/music.dart';
import 'marquee.dart';

class MiniMusicBar extends StatelessWidget {
  final Palette palette;
  const MiniMusicBar({super.key, required this.palette});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final m = context.watch<MusicController>();
    if (!m.active) return const SizedBox.shrink();

    final total = m.duration.inMilliseconds;
    final frac =
        total > 0 ? (m.position.inMilliseconds / total).clamp(0.0, 1.0) : 0.0;

    return Container(
      decoration: BoxDecoration(
        color: (p.dark ? const Color(0xFF04070A) : const Color(0xFFf2f7f3))
            .withValues(alpha: 0.94),
        border: Border.all(color: p.a.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(3),
        boxShadow: [BoxShadow(color: p.aAlpha(0.2), blurRadius: 12)],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Thin progress line.
          SizedBox(
            height: 2,
            child: Stack(
              children: [
                Positioned.fill(child: ColoredBox(color: p.dim)),
                FractionallySizedBox(
                  widthFactor: frac,
                  alignment: Alignment.centerLeft,
                  child: ColoredBox(color: p.a),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 3, 6, 4),
            child: Row(
              children: [
                GestureDetector(
                  onTap: m.toggle,
                  behavior: HitTestBehavior.opaque,
                  child: Icon(m.playing ? Icons.pause : Icons.play_arrow,
                      color: p.a, size: 20),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: SizedBox(
                    height: 18,
                    child: Marquee(text: m.title, style: glass(14, p.soft)),
                  ),
                ),
                const SizedBox(width: 7),
                GestureDetector(
                  onTap: m.next,
                  behavior: HitTestBehavior.opaque,
                  child: Icon(Icons.skip_next, color: p.mid, size: 18),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
