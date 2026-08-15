// Server-mode browsing reads the trove straight off the local disk. On the
// server device the files are *right here* — there's no need for a token or a
// network round-trip to see them. This is a LymnalClient that answers the same
// calls the browser makes (list, stat, search, open, delete, rename, mkdir,
// live changes) against the real folder on this machine, so nothing in the UI
// has to know the difference. Client mode still uses the real HTTP LymnalClient.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';

import 'api_error.dart';
import 'lymnal_client.dart';
import 'models.dart';

/// One file's tags as the isolate hands them back, keyed by the absolute path
/// that produced them so the listing can rejoin them without relying on order.
typedef _TagRow = ({
  String path,
  String? title,
  String? artist,
  String? album,
  int? durationS,
  int? year,
});

String? _clean(String? v) {
  final t = v?.trim();
  return (t == null || t.isEmpty) ? null : t;
}

/// Parse a whole folder's worth of audio files. Runs in its own isolate: the
/// parser is synchronous, so on a folder of a few thousand tracks doing this on
/// the UI isolate would lock the app for the length of the pass. A file the
/// parser can't handle yields a row of nulls instead of throwing, so one bad
/// file never costs the listing everyone else's tags.
List<_TagRow> _readTagsBatch(List<String> paths) {
  final out = <_TagRow>[];
  for (final p in paths) {
    String? title;
    String? artist;
    String? album;
    int? durationS;
    int? year;
    try {
      // getImage stays off (its default): cover art is the one genuinely large
      // allocation in a tag block, and nothing here displays it.
      final m = readMetadata(File(p));
      title = _clean(m.title);
      artist = _clean(m.artist);
      album = _clean(m.album);
      final secs = m.duration?.inSeconds;
      durationS = (secs != null && secs > 0) ? secs : null;
      year = m.year?.year;
    } catch (_) {
      // Unreadable, unsupported container, or no tag block — all the same here.
    }
    out.add((
      path: p,
      title: title,
      artist: artist,
      album: album,
      durationS: durationS,
      year: year,
    ));
  }
  return out;
}

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

  /// Order a folder the way lymnal's `sort_entries` does, key for key, so a
  /// listing looks the same whichever mode produced it: folders first whatever
  /// the order, the requested key next, then the name as a stable tiebreak.
  int _cmp(Entry a, Entry b, String sort, bool desc) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
    final primary = switch (sort) {
      'size' => a.sizeBytes.compareTo(b.sizeBytes),
      'mtime' => a.mtime.compareTo(b.mtime),
      'artist' => _tagCmp(a.artist, b.artist),
      'album' => _tagCmp(a.album, b.album),
      'title' => _tagCmp(a.title, b.title),
      _ => _nameCmp(a.name, b.name),
    };
    final ordered = desc ? -primary : primary;
    return ordered != 0 ? ordered : _nameCmp(a.name, b.name);
  }

  /// Mirrors lymnal's `tag_key`: a file carrying the tag sorts before one that
  /// doesn't, then the values compare case-folded.
  static int _tagCmp(String? a, String? b) {
    if ((a == null) != (b == null)) return a == null ? 1 : -1;
    return (a ?? '').toLowerCase().compareTo((b ?? '').toLowerCase());
  }

  static int _nameCmp(String a, String b) {
    final folded = a.toLowerCase().compareTo(b.toLowerCase());
    return folded != 0 ? folded : a.compareTo(b);
  }

  /// Whether the tag reader has a parser for this filename. Gated on the
  /// package's own list rather than the app's playable set, because the question
  /// here is what can be *parsed*, not what can be played.
  static bool _parsable(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0) return false;
    return supportedFileExtensions.contains(name.substring(dot).toLowerCase());
  }

  /// Read the folder's audio tags in one pass and fold them into [entries].
  /// Rejoined by absolute path rather than by position, so the isolate is free
  /// to return rows in whatever order it finishes them.
  Future<void> _fillTags(List<Entry> entries, String dirAbs) async {
    final paths = <String>[];
    final indexOf = <String, int>{};
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      if (e.isDir || !_parsable(e.name)) continue;
      final abs = '$dirAbs/${e.name}';
      indexOf[abs] = i;
      paths.add(abs);
    }
    if (paths.isEmpty) return;
    final rows = await Isolate.run(() => _readTagsBatch(paths));
    for (final r in rows) {
      final i = indexOf[r.path];
      if (i == null) continue;
      entries[i] = entries[i].withTags(
        title: r.title,
        artist: r.artist,
        album: r.album,
        durationS: r.durationS,
        year: r.year,
      );
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
    // Tags before the sort, or an artist or album ordering would be sorting
    // fields nothing has filled in yet.
    await _fillTags(entries, _abs(path));
    entries.sort((a, b) => _cmp(a, b, sort, order == 'desc'));
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
  Future<int> reconcile() async => 0; // the server has no queue — nothing to drain

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

  /// The file is right here on this disk, so a media backend opens it directly —
  /// nothing is fetched, copied or waited for, and no auth header is needed.
  @override
  (String uri, Map<String, String>? headers) mediaSource(String path) =>
      (_abs(path), null);

  @override
  String? localPathFor(String path) {
    try {
      return _abs(path);
    } on LymnalError {
      return null; // a path that leaves the trove isn't ours to hand out
    }
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

  // ---- uploads (server mode writes straight to the trove) ----
  //
  // On the server device an "add" is just a file landing in the trove folder on
  // this machine — there's no network, no staging service. These mirror the
  // three upload calls the transfer queue makes (init, chunk, commit), plus
  // status and cancel, by assembling the file in a temp staging file and moving
  // it into the trove on commit. Same-name overwrites and reports `replaced`,
  // matching the network server (upload.rs).

  final Map<String, _LocalUpload> _uploads = {};
  int _uploadSeq = 0;

  @override
  Future<UploadSession> uploadInit(String path, int sizeBytes,
      {String? checksum, int? mtime}) async {
    final targetAbs = _abs(path); // also rejects paths that leave the trove
    final exists =
        await FileSystemEntity.type(targetAbs) != FileSystemEntityType.notFound;
    final staging = File(
        '${Directory.systemTemp.path}/elyxr-up-${DateTime.now().microsecondsSinceEpoch}-${_uploadSeq++}.part');
    // Open the handle once and keep it, so chunks can be written at their exact
    // offset (append mode would ignore the offset and only ever tack on the end).
    final raf = await staging.open(mode: FileMode.write);
    final id = 'local_${DateTime.now().microsecondsSinceEpoch}_$_uploadSeq';
    _uploads[id] = _LocalUpload(
      targetAbs: targetAbs,
      staging: staging,
      raf: raf,
      size: sizeBytes,
      mtime: mtime,
    );
    return UploadSession(
      uploadId: id,
      chunkBytes: 8 * 1024 * 1024,
      receivedBytes: 0,
      targetExists: exists,
      expiresAt: 0,
    );
  }

  @override
  Future<(int, bool)> uploadChunk(
      String id, int offset, List<int> bytes, int total) async {
    final up = _uploads[id];
    if (up == null) {
      throw LymnalError.fromJson(
          {'code': 'NOT_FOUND', 'message': 'That upload isn\'t open.'}, 404);
    }
    await up.raf.setPosition(offset);
    await up.raf.writeFrom(bytes);
    up.received = offset + bytes.length;
    return (up.received, up.received >= total);
  }

  @override
  Future<(int, int, List<List<int>>, int)> uploadStatus(String id) async {
    final up = _uploads[id];
    if (up == null) {
      throw LymnalError.fromJson(
          {'code': 'NOT_FOUND', 'message': 'That upload isn\'t open.'}, 404);
    }
    final missing =
        up.received < up.size ? [<int>[up.received, up.size]] : <List<int>>[];
    return (up.received, up.size, missing, 0);
  }

  @override
  Future<Map<String, dynamic>> uploadCommit(String id) async {
    final up = _uploads.remove(id);
    if (up == null) {
      throw LymnalError.fromJson(
          {'code': 'NOT_FOUND', 'message': 'That upload isn\'t open.'}, 404);
    }
    final replaced =
        await FileSystemEntity.type(up.targetAbs) != FileSystemEntityType.notFound;
    await up.raf.flush();
    await up.raf.close();
    // Make sure the destination folder exists (a drop into a subfolder).
    final parent = Directory(up.targetAbs.substring(0, up.targetAbs.lastIndexOf('/')));
    if (!await parent.exists()) await parent.create(recursive: true);
    try {
      // A move is instant within one filesystem; fall back to copy across mounts
      // (the temp dir can be a different device than the trove).
      try {
        await up.staging.rename(up.targetAbs);
      } on FileSystemException {
        await up.staging.copy(up.targetAbs);
        await up.staging.delete();
      }
      if (up.mtime != null) {
        await File(up.targetAbs)
            .setLastModified(DateTime.fromMillisecondsSinceEpoch(up.mtime! * 1000));
      }
    } catch (e) {
      throw LymnalError.fromJson(
          {'code': 'IO_ERROR', 'message': 'The file couldn\'t be saved: $e'}, 500);
    }
    return {'replaced': replaced};
  }

  @override
  Future<void> uploadCancel(String id) async {
    final up = _uploads.remove(id);
    if (up == null) return;
    try {
      await up.raf.close();
    } catch (_) {}
    try {
      if (await up.staging.exists()) await up.staging.delete();
    } catch (_) {}
  }

  @override
  void close() {
    // Drop any half-assembled staging files.
    for (final up in _uploads.values) {
      up.raf.close().catchError((_) {});
      up.staging.delete().catchError((_) => up.staging);
    }
    _uploads.clear();
  }
}

/// One in-progress local upload: where it's going, its temp staging file and
/// open handle, the expected size, and the mtime to stamp it with on commit.
class _LocalUpload {
  final String targetAbs;
  final File staging;
  final RandomAccessFile raf;
  final int size;
  final int? mtime;
  int received = 0;
  _LocalUpload({
    required this.targetAbs,
    required this.staging,
    required this.raf,
    required this.size,
    required this.mtime,
  });
}
