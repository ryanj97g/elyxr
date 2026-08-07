// The Nonsense Button: a tiny unmarked control on the metal (Nostalgia Mode)
// that does something gloriously unnecessary when pressed — a shrug, a wink, a
// wandering ASCII dancer, a pointless readout. It floats the bit over the tube
// for a moment, then cleans itself up. Pure whimsy; touches nothing real.

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../design/text.dart';
import '../../design/tokens.dart';

class NonsenseButton extends StatefulWidget {
  final Palette palette;
  const NonsenseButton({super.key, required this.palette});

  @override
  State<NonsenseButton> createState() => _NonsenseButtonState();
}

class _NonsenseButtonState extends State<NonsenseButton> {
  final _rnd = Random();

  static const _bits = <String>[
    r'¯\_(ツ)_/¯',
    'beep boop',
    'nothing happened',
    'you found the button',
    '(⌐■_■)',
    '<(^_^)>',
    '01001000 01001001',
    'do not press again',
    'that tickles',
    '± 0.00 nonsense',
    'ᕕ( ᐛ )ᕗ',
    'wow. a button.',
  ];

  void _fire() {
    final overlay = Overlay.of(context);
    final text = _bits[_rnd.nextInt(_bits.length)];
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _NonsenseBit(
        text: text,
        palette: widget.palette,
        onDone: () => entry.remove(),
      ),
    );
    overlay.insert(entry);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return GestureDetector(
      onTap: _fire,
      behavior: HitTestBehavior.opaque,
      child: Tooltip(
        message: '?',
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Text('◦',
              style: TextStyle(
                fontFamily: Fonts.chassis,
                fontSize: 14,
                color: p.mt,
              )),
        ),
      ),
    );
  }
}

/// The floated bit: fades in, bobs, fades out, then removes itself.
class _NonsenseBit extends StatefulWidget {
  final String text;
  final Palette palette;
  final VoidCallback onDone;
  const _NonsenseBit(
      {required this.text, required this.palette, required this.onDone});

  @override
  State<_NonsenseBit> createState() => _NonsenseBitState();
}

class _NonsenseBitState extends State<_NonsenseBit>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1900),
  )..forward();

  @override
  void initState() {
    super.initState();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final v = _c.value;
          final opacity =
              v < 0.15 ? v / 0.15 : (v > 0.8 ? (1 - v) / 0.2 : 1.0);
          final bob = sin(v * pi * 3) * 6;
          return Center(
            child: Opacity(
              opacity: opacity.clamp(0.0, 1.0),
              child: Transform.translate(
                offset: Offset(0, -20 + bob),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(
                    color: (p.dark
                            ? const Color(0xFF04070A)
                            : const Color(0xFFf2f7f3))
                        .withValues(alpha: 0.94),
                    border: Border.all(color: p.a.withValues(alpha: 0.6)),
                    borderRadius: BorderRadius.circular(4),
                    boxShadow: [BoxShadow(color: p.aAlpha(0.3), blurRadius: 16)],
                  ),
                  child: Text(widget.text, style: glass(20, p.bright)),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
