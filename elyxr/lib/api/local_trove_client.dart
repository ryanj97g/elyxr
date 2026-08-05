// Server-mode browsing reads the trove straight off the local disk. On the
// server device the files are *right here* — there's no need for a token or a
// network round-trip to see them. This is a LymnalClient that answers the same
// calls the browser makes (list, stat, search, open, delete, rename, mkdir,
// live changes) against the real folder on this machine, so nothing in the UI
// has to know the difference. Client mode still uses the real HTTP LymnalClient.

import 'dart:async';
import 'dart:io';

import 'api_error.dart';
import 'lymnal_client.dart';
import 'models.dart';

class LocalTroveClient extends LymnalClient {
  /// The absolute trove folder on this machine (no trailing slash).
  final String root;

  LocalTroveClient(String troveRoot)
      : root = _trim(troveRoot),
        super(baseUrl: 'local:');

  static String _trim(String p) =>
      p.endsWith('/') && p.length > 1 ? p.substring(0, p.length - 1) : p;

  /// Absolute path on disk for a trove-relative path. Refuses to climb out of
  /// the trove with `..`.
  String _abs(String rel) {
    final clean = rel.split('/').where((s) => s.isNotEmpty && s != '.').toList();
    if (clean.contains('..')) {
      throw LymnalError.fromJson(
          {'code': 'BAD_PATH', 'message': 'That path leaves the trove.'}, 400);
    }
    return clean.isEmpty ? root : '$root/${clean.join('/')}';
  }

  String _rel(String abs) {
    if (abs == root) return '';
    final prefix = '$root/';
    return abs.startsWith(prefix) ? abs.substring(prefix.length) : abs;
  }

  Entry _entryFor(String name, FileStat st) => Entry(
        name: name,
        isDir: st.type == FileSystemEntityType.directory,
        sizeBytes: st.type == FileSystemEntityType.directory ? 0 : st.size,
        mtime: st.modified.millisecondsSinceEpoch ~/ 1000,
      );

  int _cmp(Entry a, Entry b, String sort) {
    switch (sort) {
      case 'size':
        return a.sizeBytes.compareTo(b.sizeBytes);
      case 'mtime':
        return a.mtime.compareTo(b.mtime);
      default:
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    }
  }

  @override
  Future<ListPage> list({
    String path = '',
    String sort = 'name',
    String order = 'asc',
    int limit = 500,
    String? cursor,
  }) async {
    final dir = Directory(_abs(path));
    if (!await dir.exists()) {
      throw LymnalError.fromJson(
          {'code': 'NOT_FOUND', 'message': 'That folder is gone.'}, 404);
    }
    final entries = <Entry>[];
    await for (final ent in dir.list(followLinks: false)) {
      final name = ent.path.split('/').last;
      if (name.isEmpty) continue;
      try {
        final st = await ent.stat();
        entries.add(_entryFor(name, st));
      } catch (_) {
        // A file that vanished mid-listing just gets skipped.
      }
    }
    entries.sort((a, b) => _cmp(a, b, sort));
    if (order == 'desc') {
      final r = entries.reversed.toList();
      entries
        ..clear()
        ..addAll(r);
    }
    return ListPage(
      path: path,
      entries: entries,
      nextCursor: null, // a local folder is returned whole; no paging
      usedBytes: 0,
      warnings: const [],
    );
  }

  @override
  Future<Entry> stat(String path) async {
    final abs = _abs(path);
    final type = await FileSystemEntity.type(abs, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw LymnalError.fromJson(
          {'code': 'NOT_FOUND', 'message': 'That item is gone.'}, 404);
    }
    final st = await FileStat.stat(abs);
    return _entryFor(path.split('/').last, st);
  }

  @override
  Future<SearchResult> search(String q, {String path = '', int limit = 200}) async {
    final needle = q.toLowerCase();
    final hits = <SearchHit>[];
    final start = Directory(_abs(path));
    if (await start.exists()) {
      try {
        await for (final ent in start.list(recursive: true, followLinks: false)) {
          if (hits.length >= limit) break;
          final name = ent.path.split('/').last;
          if (!name.toLowerCase().contains(needle)) continue;
          try {
            final st = await ent.stat();
            hits.add(SearchHit(
              path: _rel(ent.path),
              isDir: st.type == FileSystemEntityType.directory,
              sizeBytes: st.type == FileSystemEntityType.directory ? 0 : st.size,
              mtime: st.modified.millisecondsSinceEpoch ~/ 1000,
            ));
          } catch (_) {}
        }
      } catch (_) {}
    }
    return SearchResult(
        results: hits, truncated: hits.length >= limit, reason: null);
  }

  @override
  Future<Health> health() async => Health(
        version: 'local',
        build: 0,
        commit: 'local',
        uptimeS: 0,
        trove: root.split('/').last,
        usedBytes: 0,
        maxBytes: 0,
        driveFreeBytes: 0,
        pairingOpen: false,
      );

  @override
  Future<Map<String, dynamic>> mkdir(String path) async {
    await Directory(_abs(path)).create(recursive: true);
    return const {};
  }

  @override
  Future<Map<String, dynamic>> move(String from, String to,
      {String onConflict = 'fail'}) async {
    final src = _abs(from);
    final dst = _abs(to);
    if (onConflict == 'fail' &&
        await FileSystemEntity.type(dst) != FileSystemEntityType.notFound) {
      throw LymnalError.fromJson(
          {'code': 'TARGET_EXISTS', 'message': 'Something already has that name.'},
          409);
    }
    final type = await FileSystemEntity.type(src, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await Directory(src).rename(dst);
    } else {
      await File(src).rename(dst);
    }
    return const {};
  }

  @override
  Future<Map<String, dynamic>> delete(List<String> paths) async {
    final deleted = <Map<String, dynamic>>[];
    final failed = <Map<String, dynamic>>[];
    for (final p in paths) {
      try {
        final abs = _abs(p);
        final type = await FileSystemEntity.type(abs, followLinks: false);
        if (type == FileSystemEntityType.directory) {
          await Directory(abs).delete(recursive: true);
        } else {
          await File(abs).delete();
        }
        deleted.add({'path': p});
      } catch (e) {
        failed.add({'path': p, 'code': 'IO_ERROR', 'message': '$e'});
      }
    }
    return {'deleted': deleted, 'failed': failed, 'freed_bytes': 0};
  }

  @override
  Future<List<int>> downloadBytes(String path) async {
    final f = File(_abs(path));
    if (!await f.exists()) {
      throw LymnalError.fromJson(
          {'code': 'NOT_FOUND', 'message': 'That file is gone.'}, 404);
    }
    return f.readAsBytes();
  }

  @override
  Future<void> downloadTo(
    String path,
    IOSink sink, {
    int resumeFrom = 0,
    void Function(int received)? onBytes,
    bool Function()? cancelled,
  }) async {
    final f = File(_abs(path));
    if (!await f.exists()) {
      throw LymnalError.fromJson(
          {'code': 'NOT_FOUND', 'message': 'That file is gone.'}, 404);
    }
    var received = resumeFrom;
    await for (final chunk in f.openRead(resumeFrom)) {
      if (cancelled?.call() ?? false) break;
      sink.add(chunk);
      received += chunk.length;
      onBytes?.call(received);
    }
  }

  @override
  Stream<ServerEvent> events({String? lastEventId}) async* {
    // Watch the real folder (non-recursive — Linux inotify doesn't do recursive
    // through Dart). A file added or removed in the trove root becomes a change
    // event the browser already knows how to fold in, so a file dropped into the
    // trove on the server desktop shows in the server UI on its own.
    await for (final ev in Directory(root).watch()) {
      final kind = ev.type == FileSystemEvent.delete
          ? 'removed'
          : ev.type == FileSystemEvent.create
              ? 'created'
              : 'modified';
      yield ServerEvent(
          event: 'change', id: null, data: {'path': _rel(ev.path), 'kind': kind});
    }
  }

  @override
  void close() {
    // Nothing network-backed to close.
  }
}
