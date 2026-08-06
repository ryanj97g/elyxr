// Preview (§07): open a file without saving it to the download location.
// Images render inline; moving to the next and previous file in the current
// sort is possible without leaving. PDFs and video are recognised but render as
// a download offer in v1 (inline PDF/video rendering is a later iteration).

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_error.dart';
import '../api/models.dart';
import '../design/text.dart';
import '../design/tokens.dart';
import '../state/actions.dart';
import '../state/browse.dart';
import '../state/settings.dart';
import '../util/open_external.dart';

/// Show a preview over the whole window, starting at [start] within [files].
Future<void> openPreview(
  BuildContext context,
  List<Entry> files,
  int start,
) async {
  final palette = context.read<SettingsController>().palette;
  await Navigator.of(context).push(PageRouteBuilder(
    opaque: false,
    barrierColor: Colors.black87,
    pageBuilder: (_, __, ___) => _Preview(files: files, start: start, palette: palette),
  ));
}

class _Preview extends StatefulWidget {
  final List<Entry> files;
  final int start;
  final Palette palette;
  const _Preview({required this.files, required this.start, required this.palette});

  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  late int _index = widget.start;
  Uint8List? _bytes;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Entry get _entry => widget.files[_index];

  bool get _isImage => (_entry.mime ?? '').startsWith('image/');
  bool get _isPdf => _entry.mime == 'application/pdf';
  bool get _isVideo => (_entry.mime ?? '').startsWith('video/');

  Future<void> _fetch() async {
    if (!_isImage) return; // only images render inline in v1
    setState(() {
      _loading = true;
      _error = null;
      _bytes = null;
    });
    final browse = context.read<BrowseController>();
    final path = browse.path.isEmpty ? _entry.name : '${browse.path}/${_entry.name}';
    try {
      final bytes = await browse.session.client!.downloadBytes(path);
      if (mounted) setState(() => _bytes = Uint8List.fromList(bytes));
    } on LymnalError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on ConnectionError catch (e) {
      if (mounted) setState(() => _error = e.message());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _step(int delta) {
    var i = _index + delta;
    // Skip folders; only files preview.
    while (i >= 0 && i < widget.files.length && widget.files[i].isDir) {
      i += delta;
    }
    if (i < 0 || i >= widget.files.length) return;
    setState(() => _index = i);
    _fetch();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: SizedBox(
          width: kAppWidth,
          height: kAppHeight,
          child: Column(
            children: [
              // Header: name + close.
              Container(
                color: p.a,
                padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
                child: Row(
                  children: [
                    Expanded(child: Text(_entry.name, style: chassis(14, p.ink, spacing: 0.06), overflow: TextOverflow.ellipsis)),
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Text('✕', style: glass(20, p.ink)),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Container(
                  color: p.tubeBg,
                  child: Center(child: _content(p)),
                ),
              ),
              // Prev / next.
              Container(
                color: p.a,
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    GestureDetector(onTap: () => _step(-1), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Text('◂ PREV', style: chassis(12, p.ink, spacing: 0.1)))),
                    GestureDetector(onTap: () => _step(1), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Text('NEXT ▸', style: chassis(12, p.ink, spacing: 0.1)))),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _content(Palette p) {
    if (_isImage) {
      if (_loading) return Text('LOADING…', style: glass(16, p.mid));
      if (_error != null) return Padding(padding: const EdgeInsets.all(20), child: Text(_error!, style: glass(15, p.bright), textAlign: TextAlign.center));
      if (_bytes != null) return InteractiveViewer(child: Image.memory(_bytes!, fit: BoxFit.contain));
      return const SizedBox.shrink();
    }
    // PDF / video / other: open it in the default program (edits sync back), or
    // download a copy to keep.
    final kind = _isPdf ? 'PDF' : _isVideo ? 'video' : 'file';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Open this $kind in your default app — edits you save come back to the trove.',
            style: glass(17, p.bright), textAlign: TextAlign.center),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            GestureDetector(
              onTap: () => _open(context),
              child: Text('OPEN', style: chassis(12, p.a, spacing: 0.1)),
            ),
            const SizedBox(width: 28),
            GestureDetector(
              onTap: () => _download(context),
              child: Text('DOWNLOAD A COPY', style: chassis(12, p.mid, spacing: 0.1)),
            ),
          ],
        ),
      ],
    );
  }

  void _open(BuildContext context) async {
    final browse = context.read<BrowseController>();
    final client = browse.session.client;
    final path = browse.path.isEmpty ? _entry.name : '${browse.path}/${_entry.name}';
    Navigator.pop(context);
    if (client != null) {
      await OpenExternal.open(client, path, _entry.name);
    }
  }

  void _download(BuildContext context) {
    final actions = context.read<FileActions>();
    final browse = context.read<BrowseController>();
    final path = browse.path.isEmpty ? _entry.name : '${browse.path}/${_entry.name}';
    actions.startDownload([path], ResolveResult(
      fileCount: 1,
      totalBytes: _entry.sizeBytes,
      files: [ResolvedFile(path: path, name: _entry.name, sizeBytes: _entry.sizeBytes)],
      collisions: const [],
      mode: 'loose',
    ));
    Navigator.pop(context);
  }
}
