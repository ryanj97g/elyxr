// A Nostalgia-Mode heads-up readout: a small retro terminal log that narrates
// real activity — the link coming up, a download landing, an upload climbing —
// with block progress bars and status text. It reads the actual transfer/session
// state (never fakes progress) and hides itself when there's nothing to say.
// Tapping it during a transfer triggers a playful stutter; the transfer is
// unaffected.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../design/text.dart';
import '../../design/tokens.dart';
import '../../state/session.dart';
import '../../state/transfers.dart';

class TransferHud extends StatefulWidget {
  final Palette palette;
  const TransferHud({super.key, required this.palette});

  @override
  State<TransferHud> createState() => _TransferHudState();
}

class _TransferHudState extends State<TransferHud> {
  // The playful stutter: a short-lived horizontal jitter on tap.
  double _shake = 0;
  Timer? _shakeTimer;
  final _rnd = math.Random();

  void _stutter() {
    _shakeTimer?.cancel();
    var ticks = 0;
    _shakeTimer = Timer.periodic(const Duration(milliseconds: 45), (t) {
      ticks++;
      setState(() => _shake = (ticks >= 7) ? 0 : (_rnd.nextDouble() * 6 - 3));
      if (ticks >= 7) t.cancel();
    });
  }

  @override
  void dispose() {
    _shakeTimer?.cancel();
    super.dispose();
  }

  String _bar(double pct) {
    const cells = 12;
    final filled = (pct * cells).round().clamp(0, cells);
    return '${'█' * filled}${'░' * (cells - filled)}';
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final transfers = context.watch<TransferController>();
    final session = context.watch<SessionController>();

    final lines = <Widget>[];

    if (session.status == LinkStatus.connecting) {
      lines.add(Text('◐ LINKING TO ${session.serverName ?? 'server'}…',
          style: glass(15, p.a)));
    }

    for (final t in transfers.active.take(4)) {
      final arrow = t.direction == Direction.upload ? '↑' : '↓';
      final status = switch (t.state) {
        TransferState.running => '${(t.progress * 100).toStringAsFixed(0)}%',
        TransferState.waiting => 'QUEUED',
        TransferState.paused => 'PAUSED',
        TransferState.failed => 'ERR',
        TransferState.done => 'OK',
      };
      lines.add(Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Row(
          children: [
            Text('$arrow ', style: glass(15, p.a)),
            Expanded(
              child: Text(t.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: glass(15, p.soft)),
            ),
            const SizedBox(width: 6),
            Text(_bar(t.progress), style: mono(11, p.a)),
            const SizedBox(width: 6),
            SizedBox(
              width: 42,
              child: Text(status,
                  textAlign: TextAlign.right, style: glass(15, p.mid)),
            ),
          ],
        ),
      ));
    }

    if (lines.isEmpty) return const SizedBox.shrink();

    return Transform.translate(
      offset: Offset(_shake, 0),
      child: GestureDetector(
        onTap: _stutter,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
          decoration: BoxDecoration(
            color: (p.dark ? const Color(0xFF04070A) : const Color(0xFFf2f7f3))
                .withValues(alpha: 0.92),
            border: Border.all(color: p.a.withValues(alpha: 0.55)),
            borderRadius: BorderRadius.circular(3),
            boxShadow: [BoxShadow(color: p.aAlpha(0.18), blurRadius: 12)],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('▸ TRANSFER LOG',
                  style: mono(9, p.mid, spacing: 0.16)),
              const SizedBox(height: 4),
              ...lines,
            ],
          ),
        ),
      ),
    );
  }
}
