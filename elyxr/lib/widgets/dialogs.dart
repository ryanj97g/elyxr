// The prompts a person sees when changing things or starting a transfer. Plain
// words, real numbers (README ground rules). lymnal's messages are shown word
// for word; these are Elyxr's own confirmations.

import 'package:flutter/material.dart';

import '../api/api_error.dart';
import '../api/models.dart';
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

/// "Delete 12 files?" — the same guard any file manager shows.
Future<bool> showDeleteConfirm(BuildContext context, Palette p, int fileCount) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => _frame(
      p,
      'Delete ${fmtCount(fileCount, 'file')}?',
      Text('This is permanent. The space frees immediately.', style: glass(16, p.soft)),
      [
        _btn(p, 'CANCEL', () => Navigator.pop(context, false)),
        _btn(p, 'DELETE', () => Navigator.pop(context, true), accent: true),
      ],
    ),
  );
  return ok ?? false;
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

/// State the download plan before it starts: how many files, loose or zip, and
/// which older duplicates will be skipped.
Future<bool> showDownloadPlan(BuildContext context, Palette p, ResolveResult res) async {
  final lines = <String>[
    res.isZip
        ? '${fmtCount(res.fileCount, 'file')} — arriving as one zip (${fmtSize(res.totalBytes)}).'
        : '${fmtCount(res.fileCount, 'file')} — downloaded loose, three at a time (${fmtSize(res.totalBytes)}).',
  ];
  for (final c in res.collisions) {
    lines.add('Skipping ${c.skipped.length} older "${c.name}" — keeping the newest.');
  }
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => _frame(
      p,
      'Download',
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [for (final l in lines) Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(l, style: glass(16, p.soft)))],
      ),
      [
        _btn(p, 'CANCEL', () => Navigator.pop(context, false)),
        _btn(p, 'DOWNLOAD', () => Navigator.pop(context, true), accent: true),
      ],
    ),
  );
  return ok ?? false;
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
