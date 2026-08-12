// The prompts a person sees when changing things or starting a transfer. Plain
// words, real numbers (README ground rules). lymnal's messages are shown word
// for word; these are elyxr's own confirmations.

import 'package:flutter/material.dart';

import '../api/api_error.dart';
import '../design/text.dart';
import '../design/tokens.dart';
import '../util/format.dart';

Widget _frame(Palette p, String title, Widget body, List<Widget> actions) =>
    AlertDialog(
      backgroundColor: p.tubeBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(color: p.dim),
      ),
      title: Text(title, style: glass(22, p.bright)),
      content: body,
      actions: actions,
    );

TextButton _btn(Palette p, String label, VoidCallback onTap, {bool accent = false}) =>
    TextButton(
      onPressed: onTap,
      child: Text(label, style: chassis(11, accent ? p.a : p.mid, spacing: 0.1)),
    );

/// "Delete 12 files?" — the trove is shared, so this warns it removes them for
/// everyone, and offers a "don't ask again". Returns whether to delete and
/// whether the person opted out of future confirms.
Future<({bool ok, bool dontAsk})> showDeleteConfirm(
    BuildContext context, Palette p, int fileCount) async {
  bool dontAsk = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => _frame(
        p,
        'Delete ${fmtCount(fileCount, 'file')}?',
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('This permanently deletes them. The folder is shared, so they '
                'disappear from every device — not just this computer.',
                style: glass(16, p.soft)),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () => setState(() => dontAsk = !dontAsk),
              behavior: HitTestBehavior.opaque,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(dontAsk ? '▣' : '▢',
                      style: glass(20, dontAsk ? p.bright : p.foot)),
                  const SizedBox(width: 8),
                  Text("Don't ask again — I get it", style: glass(14, p.mid)),
                ],
              ),
            ),
          ],
        ),
        [
          _btn(p, 'CANCEL', () => Navigator.pop(context, false)),
          _btn(p, 'DELETE', () => Navigator.pop(context, true), accent: true),
        ],
      ),
    ),
  );
  return (ok: ok ?? false, dontAsk: dontAsk);
}

/// Name a new folder in the same action.
Future<String?> showNewFolder(BuildContext context, Palette p) async {
  final ctrl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => _frame(
      p,
      'New folder',
      TextField(
        controller: ctrl,
        autofocus: true,
        style: glass(18, p.bright),
        cursorColor: p.a,
        decoration: InputDecoration(
          hintText: 'name',
          hintStyle: glass(18, p.foot),
          enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: p.dim)),
          focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: p.a)),
        ),
        onSubmitted: (v) => Navigator.pop(context, v.trim().isEmpty ? null : v.trim()),
      ),
      [
        _btn(p, 'CANCEL', () => Navigator.pop(context, null)),
        _btn(p, 'CREATE', () {
          final v = ctrl.text.trim();
          Navigator.pop(context, v.isEmpty ? null : v);
        }, accent: true),
      ],
    ),
  );
}

/// Rename an entry.
Future<String?> showRename(BuildContext context, Palette p, String current) async {
  final ctrl = TextEditingController(text: current);
  return showDialog<String>(
    context: context,
    builder: (context) => _frame(
      p,
      'Rename',
      TextField(
        controller: ctrl,
        autofocus: true,
        style: glass(18, p.bright),
        cursorColor: p.a,
        decoration: InputDecoration(
          enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: p.dim)),
          focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: p.a)),
        ),
        onSubmitted: (v) => Navigator.pop(context, v.trim().isEmpty ? null : v.trim()),
      ),
      [
        _btn(p, 'CANCEL', () => Navigator.pop(context, null)),
        _btn(p, 'RENAME', () {
          final v = ctrl.text.trim();
          Navigator.pop(context, v.isEmpty ? null : v);
        }, accent: true),
      ],
    ),
  );
}

/// What a taken name offers: Replace, Keep both as (1), or Cancel. Keep both is
/// never chosen for you (§06).
enum ConflictChoice { replace, keepBoth, cancel }

Future<ConflictChoice> showConflict(BuildContext context, Palette p, String name) async {
  final c = await showDialog<ConflictChoice>(
    context: context,
    builder: (context) => _frame(
      p,
      'That name is already in use',
      Text('"$name" already exists. Replacing it will overwrite the other file.',
          style: glass(16, p.soft)),
      [
        _btn(p, 'CANCEL', () => Navigator.pop(context, ConflictChoice.cancel)),
        _btn(p, 'KEEP BOTH', () => Navigator.pop(context, ConflictChoice.keepBoth)),
        _btn(p, 'REPLACE', () => Navigator.pop(context, ConflictChoice.replace), accent: true),
      ],
    ),
  );
  return c ?? ConflictChoice.cancel;
}

/// Pick a folder to move the selection into. Walks the trove's folders and
/// returns the chosen folder path ('' = root), or null on cancel. [blocked] is
/// the set of folder paths that can't be entered or chosen (the folders being
/// moved — nothing can go inside itself), and [sourceFolder] is where the items
/// live now (choosing it would be a no-op, so MOVE HERE is disabled there).
Future<String?> showMoveTo(
  BuildContext context,
  Palette p, {
  required Future<List<String>> Function(String path) listFolders,
  required String sourceFolder,
  required Set<String> blocked,
  required int itemCount,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _MovePicker(
      p: p,
      listFolders: listFolders,
      sourceFolder: sourceFolder,
      blocked: blocked,
      itemCount: itemCount,
    ),
  );
}

class _MovePicker extends StatefulWidget {
  final Palette p;
  final Future<List<String>> Function(String path) listFolders;
  final String sourceFolder;
  final Set<String> blocked;
  final int itemCount;
  const _MovePicker({
    required this.p,
    required this.listFolders,
    required this.sourceFolder,
    required this.blocked,
    required this.itemCount,
  });

  @override
  State<_MovePicker> createState() => _MovePickerState();
}

class _MovePickerState extends State<_MovePicker> {
  late String _cwd = widget.sourceFolder;
  bool _loading = true;
  String? _error;
  List<String> _folders = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final f = await widget.listFolders(_cwd);
      f.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      if (mounted) {
        setState(() {
          _folders = f;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Could not read this folder';
          _loading = false;
        });
      }
    }
  }

  void _enter(String name) {
    _cwd = _cwd.isEmpty ? name : '$_cwd/$name';
    _load();
  }

  void _up() {
    final i = _cwd.lastIndexOf('/');
    _cwd = i < 0 ? '' : _cwd.substring(0, i);
    _load();
  }

  String _fullPath(String name) => _cwd.isEmpty ? name : '$_cwd/$name';
  bool _blocked(String name) => widget.blocked.contains(_fullPath(name));

  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    final crumbs = _cwd.isEmpty ? '/ELYXR' : '/ELYXR/${_cwd.toUpperCase()}';
    final canMoveHere = _cwd != widget.sourceFolder && !widget.blocked.contains(_cwd);

    final body = SizedBox(
      width: 340,
      height: 320,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(crumbs,
                    style: glass(14, p.mid), maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              if (_cwd.isNotEmpty)
                GestureDetector(
                  onTap: _up,
                  behavior: HitTestBehavior.opaque,
                  child: Text('▲ UP', style: chassis(10, p.a, spacing: 0.1)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Divider(color: p.dim, height: 1),
          Expanded(
            child: _loading
                ? Center(child: Text('READING…', style: glass(15, p.mid)))
                : _error != null
                    ? Center(child: Text(_error!, style: glass(15, p.mid)))
                    : _folders.isEmpty
                        ? Center(child: Text('NO SUBFOLDERS HERE', style: glass(14, p.foot)))
                        : ListView.builder(
                            itemCount: _folders.length,
                            itemBuilder: (context, i) {
                              final name = _folders[i];
                              final blocked = _blocked(name);
                              return GestureDetector(
                                onTap: blocked ? null : () => _enter(name),
                                behavior: HitTestBehavior.opaque,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 7),
                                  child: Row(
                                    children: [
                                      Text('█ ', style: glass(15, blocked ? p.dim : p.a)),
                                      Expanded(
                                        child: Text(name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: glass(15, blocked ? p.dim : p.bright)),
                                      ),
                                      Text('›', style: glass(15, blocked ? p.dim : p.mid)),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
          ),
        ],
      ),
    );

    return _frame(p, 'Move ${fmtCount(widget.itemCount, 'item')}', body, [
      _btn(p, 'CANCEL', () => Navigator.pop(context)),
      _btn(p, 'MOVE HERE', canMoveHere ? () => Navigator.pop(context, _cwd) : () {},
          accent: canMoveHere),
    ]);
  }
}

/// Show a lymnal error word for word, with code/request-id behind a details
/// toggle (§11).
Future<void> showLymnalError(BuildContext context, Palette p, LymnalError e) async {
  await showDialog<void>(
    context: context,
    builder: (context) => _frame(
      p,
      'That didn\'t work',
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(e.message, style: glass(16, p.bright)), // word for word
          if (e.hint != null) ...[
            const SizedBox(height: 8),
            Text(e.hint!, style: glass(15, p.mid)),
          ],
          const SizedBox(height: 10),
          ExpansionTile(
            title: Text('DETAILS', style: chassis(10, p.foot, spacing: 0.1)),
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: SelectableText(
                  'code: ${e.code}\nrequest_id: ${e.requestId ?? '—'}',
                  style: mono(12, p.foot),
                ),
              ),
            ],
          ),
        ],
      ),
      [_btn(p, 'CLOSE', () => Navigator.pop(context), accent: true)],
    ),
  );
}

/// Report a partial delete: what went, what did not, and why (§06).
Future<void> showDeleteResult(BuildContext context, Palette p, Map<String, dynamic> result) async {
  final failed = (result['failed'] as List? ?? []);
  if (failed.isEmpty) return; // all went; nothing to report
  await showDialog<void>(
    context: context,
    builder: (context) => _frame(
      p,
      'Some files could not be deleted',
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final f in failed)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('${(f as Map)['path']}: ${f['message']}', style: glass(15, p.soft)),
            ),
        ],
      ),
      [_btn(p, 'CLOSE', () => Navigator.pop(context), accent: true)],
    ),
  );
}
