// A minimal scrolling marquee: shows text static when it fits, and loops it
// smoothly when it doesn't. Used for long track titles.

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

class Marquee extends StatefulWidget {
  final String text;
  final TextStyle style;
  final double velocity; // pixels per second
  const Marquee({
    super.key,
    required this.text,
    required this.style,
    this.velocity = 28,
  });

  @override
  State<Marquee> createState() => _MarqueeState();
}

class _MarqueeState extends State<Marquee> with SingleTickerProviderStateMixin {
  final ValueNotifier<double> _t = ValueNotifier(0);
  late final Ticker _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((e) => _t.value = e.inMicroseconds / 1e6)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final tp = TextPainter(
        text: TextSpan(text: widget.text, style: widget.style),
        maxLines: 1,
        textDirection: TextDirection.ltr,
      )..layout();
      final textW = tp.width;
      final line = Text(widget.text,
          style: widget.style, maxLines: 1, softWrap: false);
      if (textW <= c.maxWidth) return line;

      const gap = 44.0;
      final span = textW + gap;
      return ClipRect(
        child: SizedBox(
          height: tp.height,
          child: AnimatedBuilder(
            animation: _t,
            builder: (context, _) {
              final off = -((_t.value * widget.velocity) % span);
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(left: off, top: 0, child: line),
                  Positioned(left: off + span, top: 0, child: line),
                ],
              );
            },
          ),
        ),
      );
    });
  }
}
