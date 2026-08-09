// The bottom of the tube while things are moving: the transfer queue (each with
// progress, speed, ETA, and controls). The selection bar now lives in the FIND
// row at the top (files_view), so nothing pops up over the file list.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../design/text.dart';
import '../design/tokens.dart';
import '../state/transfers.dart';
import '../util/format.dart';

/// The transfer queue: three run at once, the rest wait in order.
class QueueStrip extends StatelessWidget {
  final Palette palette;
  const QueueStrip({super.key, required this.palette});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final transfers = context.watch<TransferController>();
    final active = transfers.active.toList();
    if (active.isEmpty) return const SizedBox.shrink();

    return Container(
      constraints: const BoxConstraints(maxHeight: 150),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: p.dim))),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(13, 6, 13, 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('TRANSFERS', style: chassis(9.5, p.foot, spacing: 0.12)),
                GestureDetector(
                  onTap: transfers.clearFinished,
                  child: Text('CLEAR DONE', style: chassis(9.5, p.mid, spacing: 0.1)),
                ),
              ],
            ),
          ),
          Flexible(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(13, 0, 13, 8),
              shrinkWrap: true,
              children: [for (final t in active) _TransferRow(palette: p, transfer: t)],
            ),
          ),
        ],
      ),
    );
  }
}

class _TransferRow extends StatelessWidget {
  final Palette palette;
  final Transfer transfer;
  const _TransferRow({required this.palette, required this.transfer});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final t = transfer;
    final ctl = context.read<TransferController>();
    final arrow = t.direction == Direction.upload ? '↑' : '↓';
    final pct = (t.progress * 100).round();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('$arrow ', style: glass(15, p.a)),
              Expanded(
                child: Text(
                  t.replacement ? '${t.name}  (replaces)' : t.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: glass(15, p.bright),
                ),
              ),
              Text(_status(t), style: glass(13, _statusColor(t, p))),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(1),
                  child: LinearProgressIndicator(
                    value: t.totalBytes > 0 ? t.progress : null,
                    minHeight: 4,
                    backgroundColor: p.dim,
                    valueColor: AlwaysStoppedAnimation(p.a),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _controls(p, t, ctl),
            ],
          ),
          if (t.state == TransferState.running)
            Text(_speedLine(t, pct), style: glass(12, p.foot)),
          if (t.state == TransferState.failed && t.errorMessage != null)
            Text(t.errorMessage!, style: glass(12, const Color(0xFFf5b942))),
        ],
      ),
    );
  }

  Widget _controls(Palette p, Transfer t, TransferController ctl) {
    Widget btn(String glyph, VoidCallback onTap) => GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Text(glyph, style: glass(15, p.mid)),
          ),
        );
    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (t.state == TransferState.running) btn('❚❚', () => ctl.pause(t)),
      if (t.state == TransferState.paused || t.state == TransferState.waiting) btn('▶', () => ctl.resume(t)),
      if (t.state == TransferState.failed) btn('↻', () => ctl.retry(t)),
      btn('✕', () => ctl.cancel(t)),
    ]);
  }

  String _status(Transfer t) => switch (t.state) {
        TransferState.waiting => 'QUEUED',
        TransferState.running => '',
        TransferState.paused => 'PAUSED',
        TransferState.failed => 'FAILED',
        TransferState.done => 'DONE',
      };

  Color _statusColor(Transfer t, Palette p) => switch (t.state) {
        TransferState.failed => const Color(0xFFf5b942),
        TransferState.done => p.a,
        _ => p.mid,
      };

  String _speedLine(Transfer t, int pct) {
    final speed = t.speedBps > 0 ? '${fmtSize(t.speedBps.round())}/s' : '';
    final eta = t.etaSeconds;
    final etaStr = eta == null ? '' : ' · ${_fmtEta(eta)}';
    return '$pct%${speed.isEmpty ? '' : ' · $speed'}$etaStr';
  }

  String _fmtEta(int s) {
    if (s < 60) return '${s}s';
    if (s < 3600) return '${s ~/ 60}m ${s % 60}s';
    return '${s ~/ 3600}h ${(s % 3600) ~/ 60}m';
  }
}
