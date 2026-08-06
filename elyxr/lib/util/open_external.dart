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
      await Process.run('xdg-open', [local.path]);
      _watch(client, remotePath, local);
      return null;
    } catch (e) {
      return 'Could not open the file: $e';
    }
  }

  static void _watch(LymnalClient client, String remotePath, File local) {
    if (_watching.contains(remotePath)) return;
    _watching.add(remotePath);

    var lastHash = 0;
    local.readAsBytes().then((b) => lastHash = _hash(b)).catchError((_) => 0);

    Timer? settle;
    Timer? idle;
    StreamSubscription? sub;

    void disarm() {
      settle?.cancel();
      idle?.cancel();
      sub?.cancel();
      _watching.remove(remotePath);
    }

    void armIdle() {
      idle?.cancel();
      idle = Timer(const Duration(minutes: 10), disarm);
    }

    armIdle();
    sub = local.watch().listen((_) {
      armIdle();
      settle?.cancel();
      // Wait for writes to settle, then sync only if the content really changed.
      settle = Timer(const Duration(seconds: 2), () async {
        try {
          final bytes = await local.readAsBytes();
          final h = _hash(bytes);
          if (h == lastHash) return;
          lastHash = h;
          // The edit's own save time is the timestamp that rides to the trove —
          // last writer wins, and this is when this writer wrote.
          final mtime =
              (await local.lastModified()).millisecondsSinceEpoch ~/ 1000;
          await _syncBack(client, remotePath, bytes, mtime);
        } catch (_) {
          // A transient read/upload failure is retried on the next save; the
          // proxy's own queue covers a lapse.
        }
      });
    }, onError: (_) => disarm(), onDone: disarm);
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
