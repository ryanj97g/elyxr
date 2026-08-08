// Open a trove file in the system's default program, and sync your edits back.
//
// This is the app's side of the monitor. The file comes down to a temp copy and
// is handed to the OS ("open with your default app"); the temp is then watched.
// A real change — writes settled for 2 seconds, and the content actually
// different — is uploaded back through the local lymnal proxy, which queues it
// into limbo and pushes it to the trove. A pure view changes nothing, so it
// syncs nothing. Watching ends when the file goes quiet for 10 minutes.

import 'dart:async';
import 'dart:io';

import '../api/lymnal_client.dart';

class OpenExternal {
  /// Files being watched, keyed by trove path, so a second open doesn't stack a
  /// second watcher on the same file.
  static final Set<String> _watching = {};

  /// Download [remotePath] to a temp copy, open it in the default program, and
  /// begin watching for edits. Returns an error string on failure, or null.
  static Future<String?> open(
      LymnalClient client, String remotePath, String name) async {
    try {
      final dir = await Directory.systemTemp.createTemp('elyxr_open_');
      final local = File('${dir.path}/$name');
      final sink = local.openWrite();
      await client.downloadTo(remotePath, sink);
      await sink.flush();
      await sink.close();
      await _openInDefaultApp(local.path);
      _watch(client, remotePath, local);
      return null;
    } catch (e) {
      return 'Could not open the file: $e';
    }
  }

  /// Hand a file to the OS "open with the default program", the platform way:
  /// `xdg-open` on Linux, `start` on Windows, `open` on macOS.
  static Future<void> _openInDefaultApp(String path) async {
    if (Platform.isWindows) {
      // `start` is a cmd builtin; the empty "" is its title argument, so a
      // quoted path isn't mistaken for the window title.
      await Process.run('cmd', ['/c', 'start', '', path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [path]);
    } else {
      await Process.run('xdg-open', [path]);
    }
  }

  static void _watch(LymnalClient client, String remotePath, File local) {
    if (_watching.contains(remotePath)) return;
    _watching.add(remotePath);

    // The temp dir that holds this working copy (createTemp made one per open).
    // Deleting it when we're done is what reclaims the space — this is "limbo".
    final tempDir = local.parent;
    // Content already safely in the trove (initial download == the trove copy).
    var syncedHash = 0;
    local.readAsBytes().then((b) => syncedHash = _hash(b)).catchError((_) => 0);
    // Cheap gate for the periodic scan: skip the read+hash unless the file's
    // stat actually moved since we last looked.
    DateTime? seenMtime;
    int seenLen = -1;

    Timer? settle;
    Timer? idle;
    Timer? poll;
    StreamSubscription? sub;
    var finishing = false;

    // Upload the current on-disk content if it differs from what's already in
    // the trove. Returns whether anything was uploaded. This is the whole
    // auto-save-and-upload: every state the editor writes to disk goes up.
    Future<bool> syncIfChanged() async {
      final st = await local.stat();
      // Nothing touched the file since the last look — no work to do.
      if (st.modified == seenMtime && st.size == seenLen) return false;
      seenMtime = st.modified;
      seenLen = st.size;
      final bytes = await local.readAsBytes();
      final h = _hash(bytes);
      if (h == syncedHash) return false;
      // The edit's own save time is the timestamp that rides to the trove —
      // last writer wins, and this is when this writer wrote.
      final mtime = st.modified.millisecondsSinceEpoch ~/ 1000;
      await _syncBack(client, remotePath, bytes, mtime);
      syncedHash = h;
      return true;
    }

    // Tear down: make sure the final edit reached the trove, then delete the
    // working copy so it doesn't bloat the temp folder. If that last confirm
    // fails (e.g. the proxy is unreachable), keep the copy so no edit is lost —
    // a stale leftover is swept on the next launch (by then earlier saves have
    // already synced), so nothing accumulates forever either way.
    Future<void> finish() async {
      if (finishing) return;
      finishing = true;
      settle?.cancel();
      idle?.cancel();
      poll?.cancel();
      await sub?.cancel();
      try {
        await syncIfChanged();
      } catch (_) {
        _watching.remove(remotePath);
        return;
      }
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
      _watching.remove(remotePath);
    }

    void armIdle() {
      idle?.cancel();
      idle = Timer(const Duration(minutes: 10), finish);
    }

    armIdle();

    // Fast path: filesystem-event driven. When the editor writes in place the
    // event fires and we sync ~2s later. Many editors, though, save by writing
    // a temp file and renaming it over this one — which does NOT fire an event
    // here — so this path alone would miss those saves entirely.
    sub = local.watch().listen((_) {
      armIdle();
      settle?.cancel();
      // Wait for writes to settle, then sync only if the content really changed.
      settle = Timer(const Duration(seconds: 2), () async {
        try {
          await syncIfChanged();
        } catch (_) {
          // A transient read/upload failure is retried on the next scan; the
          // proxy's own queue covers a lapse.
        }
      });
    }, onError: (_) => finish(), onDone: finish);

    // Safety net + auto-save: a steady scan that uploads whatever is on disk,
    // catching the atomic-save editors the event watch misses. Any real change
    // also counts as activity, so it pushes the idle-cleanup window back.
    poll = Timer.periodic(const Duration(seconds: 30), (_) async {
      try {
        if (await syncIfChanged()) armIdle();
      } catch (_) {
        // Transient failure — the next scan (or the proxy queue) covers it.
      }
    });
  }

  /// Delete any working copies left behind by a previous run (a crash, or a
  /// force-quit before the 10-minute idle cleanup fired). Safe to call at
  /// startup: every elyxr_open_* temp dir belongs to an earlier session, and
  /// each edit was already synced back on save, so nothing unsaved is lost.
  static Future<void> sweepStale() async {
    try {
      final tmp = Directory.systemTemp;
      await for (final e in tmp.list(followLinks: false)) {
        if (e is Directory && e.path.split(Platform.pathSeparator).last
            .startsWith('elyxr_open_')) {
          try {
            await e.delete(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {
      // No temp access / nothing to sweep — never fatal.
    }
  }

  /// Upload the edited bytes back. This goes to the local proxy, which holds it
  /// in limbo and pushes it to the trove (queuing if the trove is unreachable).
  static Future<void> _syncBack(
      LymnalClient client, String remotePath, List<int> bytes, int mtime) async {
    final session = await client.uploadInit(remotePath, bytes.length, mtime: mtime);
    final chunk = session.chunkBytes;
    var offset = 0;
    while (offset < bytes.length) {
      final end = (offset + chunk) < bytes.length ? offset + chunk : bytes.length;
      await client.uploadChunk(
          session.uploadId, offset, bytes.sublist(offset, end), bytes.length);
      offset = end;
    }
    await client.uploadCommit(session.uploadId);
  }

  /// FNV-1a over the bytes — a cheap content fingerprint for change detection,
  /// kept to a positive 63-bit range so it's a plain Dart int.
  static int _hash(List<int> bytes) {
    var h = 0xcbf29ce484222325;
    for (final b in bytes) {
      h ^= b;
      h = (h * 0x100000001b3) & 0x7fffffffffffffff;
    }
    return h;
  }
}
