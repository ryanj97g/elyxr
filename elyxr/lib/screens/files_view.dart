// The files terminal: console + ticker + capacity, the find row, breadcrumbs,
// and the file list (TEXT) or tiles (GRID), with the selection bar and the
// transfer footer beneath. Everything here is "behind the glass".

import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../util/drag_out.dart';
import '../util/format.dart';
import '../widgets/dialogs.dart';
import '../widgets/tactile.dart';
import '../widgets/transfer_panel.dart';
import 'preview.dart';

class FilesView extends StatelessWidget {
  const FilesView({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>();
    final p = settings.palette;
    return DropTarget(
      onDragDone: (detail) {
        final actions = context.read<FileActions>();
        // De-dupe: a single drop can arrive with the same path more than once.
        final paths = detail.files.map((f) => f.path).toSet().toList();
        if (paths.isNotEmpty) actions.uploadPaths(paths);
      },
      child: DefaultTextStyle(
        style: glass(16, p.bright),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Console(palette: p),
            _FindRow(palette: p),
            _Breadcrumbs(palette: p),
            Expanded(
              child: settings.mode == ViewMode.text
                  ? _FileList(palette: p)
                  : _FileGrid(palette: p),
            ),
            SelectionBar(palette: p),
            Flexible(child: QueueStrip(palette: p)),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------- console ---

class _Console extends StatelessWidget {
  final Palette palette;
  const _Console({required this.palette});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final browse = context.watch<BrowseController>();
    final session = context.watch<SessionController>();
    final h = session.health;
    final used = browse.usedBytes;
    final max = browse.maxBytes;
    final pct = max > 0 ? (used / max * 100) : 0.0;

    return Container(
      padding: const EdgeInsets.fromLTRB(13, 11, 13, 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.dim)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Ticker(palette: p, used: used, max: max, name: h?.trove ?? 'elyxr'),
          const SizedBox(height: 9),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  children: [
                    _stat('HOST', session.serverName ?? '—'),
                    _stat('LINK', session.status == LinkStatus.ok ? 'UP' : 'DOWN'),
                    _stat('FREE', h != null ? '${fmtGb(h.driveFreeBytes)}G' : '—'),
                  ],
                ),
              ),
              Container(width: 1, height: 56, color: p.dim),
              const SizedBox(width: 11),
              Expanded(
                flex: 1,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('CAPACITY ${pct.toStringAsFixed(1)}%',
                        style: glass(14, p.mid)),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(fmtGb(used),
                            style: glass(28, p.bright, height: 1.02)),
                        Text(' / ${fmtGb(max)}G', style: glass(15, p.glow)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    _CapacityBars(palette: p, fraction: max > 0 ? used / max : 0),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) {
    final p = palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: Row(
        children: [
          Text(label, style: glass(15, p.mid)),
          const SizedBox(width: 8),
          // Expanded (not Flexible) so the value fills the rest and right-aligns
          // with a guaranteed gap — the label and value can't collide at any
          // text scale.
          Expanded(
            child: Text(value,
                style: glass(15, p.bright),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right),
          ),
        ],
      ),
    );
  }
}

class _CapacityBars extends StatelessWidget {
  final Palette palette;
  final double fraction;
  const _CapacityBars({required this.palette, required this.fraction});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final filled = (fraction * 20).round();
    return SizedBox(
      height: 9,
      child: Row(
        children: List.generate(20, (i) {
          final lit = i < filled;
          final warnZone = i >= 17;
          final color = lit
              ? p.a
              : warnZone
                  ? (i == 19 ? const Color(0xFF3a1d1a) : const Color(0xFF2e2f18))
                  : p.dim;
          return Expanded(
            child: Container(
              margin: const EdgeInsets.only(right: 1),
              decoration: BoxDecoration(
                color: color,
                boxShadow: lit ? [BoxShadow(color: p.aAlpha(0.6), blurRadius: 5)] : null,
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// The ticker: IBM Plex Mono, scrolling right-to-left, pausing on hover, with a
/// fixed LOG label anchoring the left edge.
class _Ticker extends StatefulWidget {
  final Palette palette;
  final int used;
  final int max;
  final String name;
  const _Ticker(
      {required this.palette, required this.used, required this.max, required this.name});

  @override
  State<_Ticker> createState() => _TickerState();
}

class _TickerState extends State<_Ticker> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 38))
        ..repeat();
  bool _hover = false;

  @override
  void didUpdateWidget(covariant _Ticker old) {
    super.didUpdateWidget(old);
    if (_hover && _c.isAnimating) _c.stop();
    if (!_hover && !_c.isAnimating) _c.repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  List<String> get _items => [
        'Trove at ${fmtGb(widget.used)} GB of ${fmtGb(widget.max)} GB',
        'Link to ${widget.name} up',
        'Ready',
      ];

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final text = _items.join('        ·        ');
    return Container(
      height: 22,
      decoration: BoxDecoration(
        color: p.aAlpha(0.03),
        border: Border(
          top: BorderSide(color: p.dim),
          bottom: BorderSide(color: p.dim),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border(right: BorderSide(color: p.dim)),
            ),
            child: Text('LOG', style: mono(8.5, p.mid, spacing: 0.13)),
          ),
          Expanded(
            child: MouseRegion(
              onEnter: (_) {
                setState(() => _hover = true);
                _c.stop();
              },
              onExit: (_) {
                setState(() => _hover = false);
                _c.repeat();
              },
              child: ClipRect(
                child: AnimatedBuilder(
                  animation: _c,
                  builder: (context, _) {
                    return LayoutBuilder(builder: (context, cons) {
                      final w = cons.maxWidth;
                      final dx = w - (_c.value * (w + 400));
                      return Transform.translate(
                        offset: Offset(dx, 0),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            text,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.visible,
                            style: mono(11.5, p.bright, spacing: 0)
                                .copyWith(shadows: [Shadow(color: p.aAlpha(0.4), blurRadius: 7)]),
                          ),
                        ),
                      );
                    });
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------- find row ---

class _FindRow extends StatefulWidget {
  final Palette palette;
  const _FindRow({required this.palette});

  @override
  State<_FindRow> createState() => _FindRowState();
}

class _FindRowState extends State<_FindRow> {
  final _ctrl = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final browse = context.watch<BrowseController>();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.dim))),
      child: Row(
        children: [
          Text('FIND', style: glass(16, p.bright)),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: _ctrl,
              style: glass(16, p.bright),
              cursorColor: p.a,
              cursorWidth: 8,
              cursorHeight: 14,
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
              onChanged: (v) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 250),
                    () => browse.setQuery(v));
              },
            ),
          ),
          GestureDetector(
            onTap: browse.cycleSort,
            behavior: HitTestBehavior.opaque,
            child: Text('${browse.sort.label} ▾',
                style: chassis(10, p.mid, spacing: 0.09)),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------- breadcrumbs ---

class _Breadcrumbs extends StatelessWidget {
  final Palette palette;
  const _Breadcrumbs({required this.palette});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final browse = context.watch<BrowseController>();
    final parts = browse.crumbs;
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 6, 13, 4),
      child: Row(
        children: [
          Flexible(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(
                children: [
                  _crumb('/ELYXR', p.glow, () => browse.goToCrumb(-1)),
                  for (var i = 0; i < parts.length; i++)
                    _crumb(
                      ' / ${parts[i].toUpperCase()}',
                      i == parts.length - 1 ? p.bright : p.glow,
                      () => browse.goToCrumb(i),
                    ),
                ],
              ),
            ),
          ),
          const Spacer(),
          GestureDetector(
            onTap: () => _newFolder(context, browse, p),
            behavior: HitTestBehavior.opaque,
            child: Text('＋ NEW', style: chassis(10, p.mid, spacing: 0.09)),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: () => _pickUpload(context),
            behavior: HitTestBehavior.opaque,
            child: Text('▴ ADD', style: chassis(10, p.mid, spacing: 0.09)),
          ),
          if (browse.canGoUp) ...[
            const SizedBox(width: 12),
            GestureDetector(
              onTap: browse.goUp,
              behavior: HitTestBehavior.opaque,
              child: Text('▲ UP', style: chassis(10, p.mid, spacing: 0.09)),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _newFolder(BuildContext context, BrowseController browse, Palette p) async {
    final name = await showNewFolder(context, p);
    if (name == null || !context.mounted) return;
    try {
      await browse.newFolder(name);
    } on LymnalError catch (e) {
      if (context.mounted) await showLymnalError(context, p, e);
    }
  }

  Future<void> _pickUpload(BuildContext context) async {
    final actions = context.read<FileActions>();
    final files = await openFiles();
    if (files.isEmpty) return;
    await actions.uploadPaths(files.map((f) => f.path).toList());
  }

  Widget _crumb(String label, Color color, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Text(label, style: glass(15, color)),
      );
}

// ------------------------------------------------------------ file list ---

class _FileList extends StatefulWidget {
  final Palette palette;
  const _FileList({required this.palette});

  @override
  State<_FileList> createState() => _FileListState();
}

class _FileListState extends State<_FileList> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  void _onScroll() {
    final browse = context.read<BrowseController>();
    browse.rememberScroll(_scroll.offset);
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) {
      browse.loadMore();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final browse = context.watch<BrowseController>();

    // Search overlay takes over the list area when a query is active.
    if (browse.query.trim().length >= 2) {
      return _SearchResults(palette: p);
    }

    final content = _stateOr(context, browse, p, () {
      final d = context.read<SettingsController>().density;
      final rows = browse.entries;
      return ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(7, 2, 7, 0),
        itemCount: rows.length + 2,
        itemBuilder: (context, i) {
          if (i == 0) return _header(p);
          if (i == rows.length + 1) return _footer(p, rows.length);
          final index = i - 1;
          return _Row(
            palette: p,
            entry: rows[index],
            index: index,
            density: d,
            selected: browse.selection.contains(rows[index].name),
            marked: browse.markedEntry == rows[index].name,
          );
        },
      );
    });
    return content;
  }

  Widget _header(Palette p) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.dim))),
        child: Row(
          children: [
            const SizedBox(width: 16),
            const SizedBox(width: 7),
            Expanded(child: Text('NAME', style: chassis(9.5, p.foot, spacing: 0.12))),
            Text('SIZE', style: chassis(9.5, p.foot, spacing: 0.12)),
          ],
        ),
      );

  Widget _footer(Palette p, int n) => Padding(
        padding: const EdgeInsets.all(6),
        child: Text('──── ${fmtCount(n, 'ITEM').toUpperCase()} ────',
            style: glass(14, p.foot, spacing: 0.06)),
      );
}

/// A single file row: glyph (16px), name, size (right). Folders get a solid █
/// in the accent; files a hollow ▫ in mid. (DESIGN.md · File rows)
class _Row extends StatelessWidget {
  final Palette palette;
  final Entry entry;
  final int index;
  final Density density;
  final bool selected;
  final bool marked;

  const _Row({
    required this.palette,
    required this.entry,
    required this.index,
    required this.density,
    required this.selected,
    required this.marked,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final browse = context.read<BrowseController>();
    final band = index.isOdd ? p.aAlpha(0.043) : null;
    final isDir = entry.isDir;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // A single click selects (so a folder can be selected to delete/move,
      // like any file); a folder opens on double-click and a file previews —
      // the standard file-manager convention.
      onTap: () {
        if (HardwareKeyboard.instance.isShiftPressed) {
          browse.selectRange(index);
        } else {
          browse.toggle(index);
        }
      },
      onDoubleTap: () {
        if (isDir) {
          browse.open(entry.name.isEmpty
              ? browse.path
              : (browse.path.isEmpty ? entry.name : '${browse.path}/${entry.name}'));
        } else {
          openPreview(context, browse.entries, index);
        }
      },
      // Drag a file sideways to pull it out of the window; where you drop it is
      // where it downloads. A vertical drag still scrolls the list.
      onHorizontalDragStart: isDir
          ? null
          : (_) {
              final path = browse.path.isEmpty
                  ? entry.name
                  : '${browse.path}/${entry.name}';
              DragOut.begin(path, entry.name);
            },
      onLongPress: () {
        // Long-pressing an audio file streams it from the trove into the music
        // player (any mode). Non-audio files rename, as before.
        if (!isDir && isAudioName(entry.name)) {
          final client = context.read<SessionController>().client;
          if (client != null) {
            final path = browse.path.isEmpty
                ? entry.name
                : '${browse.path}/${entry.name}';
            context
                .read<MusicController>()
                .playTroveFile(client, path, entry.name);
            return;
          }
        }
        _renameEntry(context, browse, p, entry.name);
      },
      // Hover on desktop / press on touch lights the row the same way.
      child: Tactile(
        accent: p.a,
        child: Container(
        padding: EdgeInsets.symmetric(horizontal: 6, vertical: density.pad),
        decoration: BoxDecoration(
          color: selected ? p.aAlpha(0.15) : band,
          border: selected
              ? Border(left: BorderSide(color: p.a, width: 2))
              : marked
                  ? Border(left: BorderSide(color: p.a.withValues(alpha: 0.5), width: 2))
                  : null,
        ),
        child: Row(
          children: [
            SizedBox(
              width: 16,
              child: Text(
                isDir ? '█' : '▫',
                style: glass(density.font, isDir ? (selected ? p.bright : p.a) : p.mid),
              ),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: glass(
                  density.font,
                  selected
                      ? (p.dark ? Colors.white : Colors.black)
                      : (isDir ? p.bright : p.soft),
                ).copyWith(
                  shadows: selected ? [Shadow(color: p.aAlpha(0.7), blurRadius: 8)] : null,
                ),
              ),
            ),
            SizedBox(
              width: 56,
              child: Text(
                isDir ? '${entry.childCount ?? ''}' : fmtSize(entry.sizeBytes),
                textAlign: TextAlign.right,
                style: glass(density.font, p.mid),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }

  /// Rename with the taken-name flow: Replace / Keep both as (1) / Cancel.
  Future<void> _renameEntry(
      BuildContext context, BrowseController browse, Palette p, String name) async {
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
}

// ------------------------------------------------------------- file grid ---

class _FileGrid extends StatelessWidget {
  final Palette palette;
  const _FileGrid({required this.palette});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final browse = context.watch<BrowseController>();
    if (browse.query.trim().length >= 2) return _SearchResults(palette: p);

    return _stateOr(context, browse, p, () {
      final rows = browse.entries;
      return GridView.builder(
        padding: const EdgeInsets.all(10),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 0.82,
        ),
        itemCount: rows.length,
        itemBuilder: (context, i) {
          final e = rows[i];
          final selected = browse.selection.contains(e.name);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            // Single click selects; double-click opens a folder or previews a
            // file — so a folder can be selected to delete/move like any file.
            onTap: () => browse.toggle(i),
            onDoubleTap: () {
              if (e.isDir) {
                browse.open(browse.path.isEmpty ? e.name : '${browse.path}/${e.name}');
              } else {
                openPreview(context, browse.entries, i);
              }
            },
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: selected ? p.aAlpha(0.15) : null,
                border: Border.all(color: selected ? p.a : p.dim),
                borderRadius: BorderRadius.circular(3),
                boxShadow: selected ? [BoxShadow(color: p.aAlpha(0.33), blurRadius: 12)] : null,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(e.isDir ? '█' : '▫',
                      style: glass(e.isDir ? 42 : 36, e.isDir ? p.a : p.glow)),
                  const SizedBox(height: 8),
                  Text(e.name,
                      maxLines: 2,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: glass(15, selected ? (p.dark ? Colors.white : Colors.black) : (e.isDir ? p.bright : p.soft))),
                  const SizedBox(height: 2),
                  Text(e.isDir ? '${e.childCount ?? 0} items' : fmtSize(e.sizeBytes),
                      style: glass(12, p.mid)),
                ],
              ),
            ),
          );
        },
      );
    });
  }
}

// ------------------------------------------------------ shared list states ---

/// Render loading / empty / gone / offline distinctly, or the built content.
Widget _stateOr(
    BuildContext context, BrowseController browse, Palette p, Widget Function() build) {
  switch (browse.state) {
    case FolderState.loading:
      return Center(child: Text('READING…', style: glass(16, p.mid)));
    case FolderState.empty:
      return Center(child: Text('THIS FOLDER IS EMPTY', style: glass(16, p.mid)));
    case FolderState.gone:
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('THIS FOLDER IS NO LONGER HERE', style: glass(16, p.mid)),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: browse.goUp,
              child: Text('▲ GO UP', style: chassis(11, p.a, spacing: 0.1)),
            ),
          ],
        ),
      );
    case FolderState.offline:
      return _OfflineNotice(palette: p, fault: browse.fault);
    case FolderState.ready:
      return build();
  }
}

/// The three unreachable states, each with its own message and next step.
class _OfflineNotice extends StatelessWidget {
  final Palette palette;
  final ConnectionFault? fault;
  const _OfflineNotice({required this.palette, required this.fault});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final session = context.read<SessionController>();
    final err = ConnectionError(fault ?? ConnectionFault.unreachable,
        serverName: session.serverName);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(err.message(),
                textAlign: TextAlign.center, style: glass(17, p.bright)),
            const SizedBox(height: 10),
            if (fault == ConnectionFault.notApproved)
              GestureDetector(
                onTap: () => session.forget(),
                child: Text('REQUEST ACCESS AGAIN',
                    style: chassis(11, p.a, spacing: 0.1)),
              )
            else
              Text('RETRYING…', style: glass(14, p.mid)),
          ],
        ),
      ),
    );
  }
}

// --------------------------------------------------------- search results ---

class _SearchResults extends StatelessWidget {
  final Palette palette;
  const _SearchResults({required this.palette});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final browse = context.watch<BrowseController>();
    if (browse.searching) {
      return Center(child: Text('SEARCHING…', style: glass(16, p.mid)));
    }
    final res = browse.searchResult;
    if (res == null || res.results.isEmpty) {
      return Center(child: Text('NOTHING MATCHES', style: glass(16, p.mid)));
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(7, 2, 7, 0),
      children: [
        if (res.truncated)
          Padding(
            padding: const EdgeInsets.all(6),
            child: Text(
              res.reason == TruncateReason.limit
                  ? 'TOO MANY MATCHES — SHOWING THE FIRST FOUND, NOT ALL'
                  : 'SEARCH RAN OUT OF TIME — RESULTS ARE INCOMPLETE',
              style: glass(13, const Color(0xFFf5b942)),
            ),
          ),
        for (final hit in res.results)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => browse.openHit(hit),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
              child: Row(
                children: [
                  SizedBox(width: 16, child: Text(hit.isDir ? '█' : '▫', style: glass(16, hit.isDir ? p.a : p.mid))),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(hit.name, style: glass(16, p.bright), maxLines: 1, overflow: TextOverflow.ellipsis),
                        if (hit.folder.isNotEmpty)
                          Text('in /${hit.folder}', style: glass(12, p.foot), maxLines: 1, overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

