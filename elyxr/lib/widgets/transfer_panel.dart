// The bottom of the tube when things are moving or selected: the selection bar
// (Download / Move / Delete, with the server's real count and size), over the
// transfer queue (each with progress, speed, ETA, and controls).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_error.dart';
import '../api/models.dart';
import '../design/text.dart';
import '../design/tokens.dart';
import '../state/actions.dart';
import '../state/browse.dart';
import '../state/music.dart';
import '../state/session.dart';
import '../state/settings.dart';
import '../state/transfers.dart';
import '../util/format.dart';
import 'dialogs.dart';

class SelectionBar extends StatefulWidget {
  final Palette palette;
  const SelectionBar({super.key, required this.palette});

  @override
  State<SelectionBar> createState() => _SelectionBarState();
}

class _SelectionBarState extends State<SelectionBar> {
  ResolveResult? _res;
  List<String>? _forPaths;

  Future<void> _ensureResolved(BrowseController browse, FileActions actions) async {
    final paths = browse.selectionPaths;
    if (_forPaths != null && _forPaths!.length == paths.length && _forPaths!.toSet().containsAll(paths)) {
      return;
    }
    _forPaths = paths;
    final res = await actions.resolve(paths);
    if (mounted) setState(() => _res = res);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final browse = context.watch<BrowseController>();
    final actions = context.read<FileActions>();
    if (!browse.hasSelection) return const SizedBox.shrink();
    _ensureResolved(browse, actions);

    final figures = _res == null
        ? fmtCount(browse.selection.length, 'item')
        : '${fmtCount(_res!.fileCount, 'file')} · ${fmtSize(_res!.totalBytes)}';

    // When exactly one thing is selected, the box shows single-file actions:
    // PLAY (for audio, into the in-app player) and RENAME — the two things that
    // used to hide on a long-press before click-and-hold became multi-select.
    Entry? single;
    if (browse.selection.length == 1) {
      final name = browse.selection.first;
      for (final e in browse.entries) {
        if (e.name == name) {
          single = e;
          break;
        }
      }
    }
    final canPlay =
        single != null && !single.isDir && isAudioName(single.name);

    return Container(
      padding: const EdgeInsets.fromLTRB(13, 8, 13, 6),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.dim))),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(child: Text(figures, style: glass(16, p.bright), overflow: TextOverflow.ellipsis)),
          Flexible(
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 12,
              runSpacing: 2,
              children: [
                if (canPlay)
                  _action(p, 'PLAY', () => _play(context, browse, single!)),
                if (single != null)
                  _action(p, 'RENAME',
                      () => _rename(context, browse, p, single!.name)),
                _action(p, 'DOWNLOAD', () => _download(context, browse, actions)),
                _action(p, 'DELETE', () => _delete(context, browse, p)),
                GestureDetector(
                  onTap: browse.clearSelection,
                  child: Text('CLEAR', style: glass(16, p.mid)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Stream the selected audio file from the trove into the in-app player.
  void _play(BuildContext context, BrowseController browse, Entry entry) {
    final client = context.read<SessionController>().client;
    if (client == null) return;
    final path = browse.path.isEmpty
        ? entry.name
        : '${browse.path}/${entry.name}';
    context.read<MusicController>().playTroveFile(client, path, entry.name);
  }

  /// Rename with the taken-name flow: Replace / Keep both as (1) / Cancel.
  Future<void> _rename(BuildContext context, BrowseController browse, Palette p,
      String name) async {
    final newName = await showRename(context, p, name);
    if (newName == null || newName == name || !context.mounted) return;
    try {
      await browse.rename(name, newName);
    } on LymnalError catch (e) {
      if (e.code == 'TARGET_EXISTS' && context.mounted) {
        final choice = await showConflict(context, p, newName);
        switch (choice) {
          case ConflictChoice.replace:
            await browse.rename(name, newName, onConflict: 'replace');
            break;
          case ConflictChoice.keepBoth:
            await browse.rename(name, newName, onConflict: 'suffix');
            break;
          case ConflictChoice.cancel:
            break;
        }
      } else if (context.mounted) {
        await showLymnalError(context, p, e);
      }
    }
  }

  Widget _action(Palette p, String label, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Text(label,
            style: glass(16, p.a).copyWith(shadows: [Shadow(color: p.aAlpha(0.53), blurRadius: 7)])),
      );

  Future<void> _download(BuildContext context, BrowseController browse, FileActions actions) async {
    // Clicking download IS the decision — no plan to confirm. The resolved plan
    // (loose vs. one zip, and skipping older duplicates) still applies; it just
    // isn't narrated back at you.
    final paths = browse.selectionPaths;
    final res = _res ?? await actions.resolve(paths);
    if (res == null) return;
    actions.startDownload(paths, res);
    browse.clearSelection();
  }

  Future<void> _delete(BuildContext context, BrowseController browse, Palette p) async {
    final settings = context.read<SettingsController>();
    final count = _res?.fileCount ?? browse.selection.length;
    if (settings.confirmDelete) {
      final r = await showDeleteConfirm(context, p, count);
      if (!r.ok || !context.mounted) return;
      if (r.dontAsk) settings.confirmDelete = false;
    }
    try {
      final result = await browse.deletePaths(browse.selectionPaths);
      if (context.mounted) await showDeleteResult(context, p, result);
    } on LymnalError catch (e) {
      if (context.mounted) await showLymnalError(context, p, e);
    }
  }
}

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
