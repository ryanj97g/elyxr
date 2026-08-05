// The transfer queue (§05). Three run at once; the rest wait in order. Each
// knows its file, folder, direction, bytes done against total, speed, ETA, and
// state. Each can be paused, resumed, cancelled, or (on failure) retried. The
// queue is written to disk as it changes, so closing Elyxr mid-transfer and
// reopening resumes rather than restarts.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../api/api_error.dart';
import '../api/lymnal_client.dart';

enum Direction { upload, download }

enum TransferState { waiting, running, paused, failed, done }

class Transfer {
  final String id;
  final Direction direction;
  final String name;

  /// Trove-relative path — the source for a download, the target for an upload.
  final String remotePath;

  /// Local file — the destination for a download, the source for an upload.
  final String localPath;

  int totalBytes;
  int doneBytes;
  TransferState state;
  String? errorMessage; // lymnal's message, word for word, on failure
  String? errorCode;
  int attempts;
  String? uploadId; // set once an upload has begun, for resume
  bool replacement; // labelled as a replacement (§05)

  /// When set, this download is a streamed zip of these trove paths rather than
  /// a single file (§05, the "more than five files" mode).
  List<String>? zipPaths;

  // Transient, not persisted.
  double speedBps = 0;
  bool cancelRequested = false;
  bool pauseRequested = false;

  Transfer({
    required this.id,
    required this.direction,
    required this.name,
    required this.remotePath,
    required this.localPath,
    this.totalBytes = 0,
    this.doneBytes = 0,
    this.state = TransferState.waiting,
    this.errorMessage,
    this.errorCode,
    this.attempts = 0,
    this.uploadId,
    this.replacement = false,
    this.zipPaths,
  });

  double get progress => totalBytes > 0 ? doneBytes / totalBytes : 0;

  /// Seconds remaining at the current speed, or null when unknown.
  int? get etaSeconds {
    if (speedBps <= 0 || totalBytes <= 0) return null;
    return ((totalBytes - doneBytes) / speedBps).round();
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'direction': direction.name,
        'name': name,
        'remotePath': remotePath,
        'localPath': localPath,
        'totalBytes': totalBytes,
        'doneBytes': doneBytes,
        // A running transfer was interrupted by the close; reopen resumes it.
        'state': (state == TransferState.running ? TransferState.waiting : state).name,
        'errorMessage': errorMessage,
        'errorCode': errorCode,
        'attempts': attempts,
        'uploadId': uploadId,
        'replacement': replacement,
        'zipPaths': zipPaths,
      };

  factory Transfer.fromJson(Map<String, dynamic> j) => Transfer(
        id: j['id'] as String,
        direction: Direction.values.byName(j['direction'] as String),
        name: j['name'] as String,
        remotePath: j['remotePath'] as String,
        localPath: j['localPath'] as String,
        totalBytes: (j['totalBytes'] as num?)?.toInt() ?? 0,
        doneBytes: (j['doneBytes'] as num?)?.toInt() ?? 0,
        state: TransferState.values.byName(j['state'] as String? ?? 'waiting'),
        errorMessage: j['errorMessage'] as String?,
        errorCode: j['errorCode'] as String?,
        attempts: (j['attempts'] as num?)?.toInt() ?? 0,
        uploadId: j['uploadId'] as String?,
        replacement: j['replacement'] as bool? ?? false,
        zipPaths: (j['zipPaths'] as List?)?.map((e) => e as String).toList(),
      );
}

/// The queue and its pump. Injectable client-getter and storage file so it can
/// be driven in tests against a fake server and a temp directory.
class TransferController extends ChangeNotifier {
  final LymnalClient? Function() _client;
  final File _store;
  final int Function() _maxConcurrent;

  /// How the upload chunk size is chosen when a session doesn't declare one.
  static const int _defaultChunk = 8 * 1024 * 1024;
  static const int _maxAttempts = 5;

  final List<Transfer> _queue = [];
  int _running = 0;
  bool _saveScheduled = false;

  TransferController(
    this._client,
    this._store, {
    int Function()? maxConcurrent,
  }) : _maxConcurrent = maxConcurrent ?? (() => 3);

  List<Transfer> get queue => List.unmodifiable(_queue);
  bool get isEmpty => _queue.isEmpty;
  Iterable<Transfer> get active =>
      _queue.where((t) => t.state != TransferState.done);

  /// Load a persisted queue and resume anything that was mid-flight.
  Future<void> load() async {
    if (!await _store.exists()) return;
    try {
      final list = jsonDecode(await _store.readAsString()) as List;
      _queue
        ..clear()
        ..addAll(list.map((j) => Transfer.fromJson((j as Map).cast())));
    } catch (_) {
      // A corrupt queue file is discarded rather than blocking startup.
    }
    notifyListeners();
    _pump();
  }

  // ---- adding work ----

  Transfer enqueueDownload({
    required String remotePath,
    required String localPath,
    required String name,
    int totalBytes = 0,
  }) {
    final t = Transfer(
      id: _id(),
      direction: Direction.download,
      name: name,
      remotePath: remotePath,
      localPath: localPath,
      totalBytes: totalBytes,
    );
    _queue.add(t);
    _persist();
    _pump();
    return t;
  }

  /// A "more than five files" download: one streamed zip of [zipPaths].
  Transfer enqueueZip({
    required List<String> zipPaths,
    required String localPath,
    required String name,
  }) {
    final t = Transfer(
      id: _id(),
      direction: Direction.download,
      name: name,
      remotePath: '',
      localPath: localPath,
      zipPaths: zipPaths,
    );
    _queue.add(t);
    _persist();
    _pump();
    return t;
  }

  Transfer enqueueUpload({
    required String localPath,
    required String remotePath,
    required String name,
    bool replacement = false,
  }) {
    // Guard against a duplicated drop: desktop_drop on Linux can deliver the
    // same file more than once (or fire onDragDone repeatedly). If an upload of
    // this file to this path is already in flight, reuse it instead of sending
    // it again.
    if (!replacement) {
      for (final t in _queue) {
        if (t.direction == Direction.upload &&
            t.state != TransferState.done &&
            t.remotePath == remotePath &&
            t.localPath == localPath) {
          return t;
        }
      }
    }
    final t = Transfer(
      id: _id(),
      direction: Direction.upload,
      name: name,
      remotePath: remotePath,
      localPath: localPath,
      replacement: replacement,
    );
    _queue.add(t);
    _persist();
    _pump();
    return t;
  }

  // ---- controls ----

  void pause(Transfer t) {
    if (t.state == TransferState.running) {
      t.pauseRequested = true;
    } else if (t.state == TransferState.waiting) {
      t.state = TransferState.paused;
    }
    _persist();
    notifyListeners();
  }

  void resume(Transfer t) {
    if (t.state == TransferState.paused || t.state == TransferState.failed) {
      t.state = TransferState.waiting;
      t.pauseRequested = false;
      t.attempts = 0;
      t.errorMessage = null;
      _persist();
      _pump();
    }
  }

  void retry(Transfer t) => resume(t);

  Future<void> cancel(Transfer t) async {
    t.cancelRequested = true;
    if (t.state != TransferState.running) {
      await _finalizeCancel(t);
    }
    notifyListeners();
  }

  void clearFinished() {
    _queue.removeWhere((t) => t.state == TransferState.done);
    _persist();
    notifyListeners();
  }

  // ---- the pump ----

  void _pump() {
    final max = _maxConcurrent();
    for (final t in _queue) {
      if (_running >= max) break;
      if (t.state == TransferState.waiting) {
        _running++;
        t.state = TransferState.running;
        notifyListeners();
        unawaited(_run(t).whenComplete(() {
          _running--;
          _pump();
        }));
      }
    }
  }

  Future<void> _run(Transfer t) async {
    final client = _client();
    if (client == null) {
      _fail(t, 'IO_ERROR', 'Not connected to a server.', retryable: true);
      return;
    }
    try {
      if (t.direction == Direction.download) {
        await _download(client, t);
      } else {
        await _upload(client, t);
      }
      if (t.cancelRequested) {
        await _finalizeCancel(t);
      } else if (t.pauseRequested) {
        t.pauseRequested = false;
        t.state = TransferState.paused;
      } else {
        t.state = TransferState.done;
      }
    } on ConnectionError catch (e) {
      // A connection blip retries on its own, backing off, up to five attempts.
      t.attempts++;
      if (t.attempts < _maxAttempts && !t.cancelRequested) {
        await Future.delayed(_backoff(t.attempts));
        t.state = TransferState.waiting;
      } else {
        _fail(t, 'UNREACHABLE', e.message(), retryable: true);
      }
    } on LymnalError catch (e) {
      // A coded refusal (over the limit, etc.) is real; carry it word for word
      // and do not retry on its own.
      _fail(t, e.code, e.message);
    } catch (e) {
      _fail(t, 'IO_ERROR', 'Something went wrong: $e', retryable: true);
    }
    _persist();
    notifyListeners();
  }

  Future<void> _download(LymnalClient client, Transfer t) async {
    final part = File('${t.localPath}.part');
    final resumeFrom = await part.exists() ? await part.length() : 0;
    t.doneBytes = resumeFrom;
    // A zip download can't resume mid-stream (it's generated on the fly), so
    // start it fresh each attempt.
    final sink = t.zipPaths != null
        ? part.openWrite(mode: FileMode.write)
        : part.openWrite(mode: FileMode.append);
    final stopwatch = Stopwatch()..start();
    var lastBytes = t.zipPaths != null ? 0 : resumeFrom;
    void onBytes(int received) {
      t.doneBytes = received;
      if (stopwatch.elapsedMilliseconds > 500) {
        t.speedBps = (received - lastBytes) * 1000 / stopwatch.elapsedMilliseconds;
        lastBytes = received;
        stopwatch.reset();
        notifyListeners();
      }
    }

    bool cancelled() => t.cancelRequested || t.pauseRequested;
    try {
      if (t.zipPaths != null) {
        t.doneBytes = 0;
        await client.zipTo(t.zipPaths!, t.name, sink,
            onBytes: onBytes, cancelled: cancelled);
      } else {
        await client.downloadTo(t.remotePath, sink,
            resumeFrom: resumeFrom, onBytes: onBytes, cancelled: cancelled);
      }
    } finally {
      await sink.close();
    }
    if (t.cancelRequested || t.pauseRequested) return;
    // Land the completed file, never overwriting an existing one (§05).
    final dest = await _uniqueDest(t.localPath);
    await part.rename(dest);
  }

  Future<void> _upload(LymnalClient client, Transfer t) async {
    final file = File(t.localPath);
    final size = await file.length();
    t.totalBytes = size;

    int chunkBytes = _defaultChunk;
    List<List<int>> missing;
    if (t.uploadId == null) {
      final s = await client.uploadInit(t.remotePath, size,
          mtime: (await file.lastModified()).millisecondsSinceEpoch ~/ 1000);
      t.uploadId = s.uploadId;
      chunkBytes = s.chunkBytes;
      missing = [
        [0, size]
      ];
    } else {
      // Resume from what lymnal already holds.
      final (received, _, miss, _) = await client.uploadStatus(t.uploadId!);
      t.doneBytes = received;
      missing = miss.isEmpty ? [] : miss;
    }

    final raf = await file.open();
    try {
      for (final range in missing) {
        var offset = range[0];
        final end = range[1];
        while (offset < end) {
          if (t.cancelRequested || t.pauseRequested) return;
          final len = (end - offset) < chunkBytes ? (end - offset) : chunkBytes;
          await raf.setPosition(offset);
          final bytes = await raf.read(len);
          final (received, _) =
              await client.uploadChunk(t.uploadId!, offset, bytes, size);
          t.doneBytes = received;
          notifyListeners();
          offset += len;
        }
      }
    } finally {
      await raf.close();
    }
    if (t.cancelRequested || t.pauseRequested) return;
    final res = await client.uploadCommit(t.uploadId!);
    t.replacement = res['replaced'] as bool? ?? t.replacement;
    t.doneBytes = t.totalBytes;
  }

  Future<void> _finalizeCancel(Transfer t) async {
    if (t.direction == Direction.upload && t.uploadId != null) {
      // Tell lymnal to discard its staging file, leaving nothing behind.
      try {
        await _client()?.uploadCancel(t.uploadId!);
      } catch (_) {}
    } else if (t.direction == Direction.download) {
      final part = File('${t.localPath}.part');
      if (await part.exists()) await part.delete();
    }
    _queue.remove(t);
    _persist();
  }

  Future<String> _uniqueDest(String path) async {
    if (!await File(path).exists()) return path;
    final dot = path.lastIndexOf('.');
    final slash = path.lastIndexOf(Platform.pathSeparator);
    final hasExt = dot > slash;
    final stem = hasExt ? path.substring(0, dot) : path;
    final ext = hasExt ? path.substring(dot) : '';
    for (var n = 1; n < 100000; n++) {
      final candidate = '$stem ($n)$ext';
      if (!await File(candidate).exists()) return candidate;
    }
    return path;
  }

  void _fail(Transfer t, String code, String message, {bool retryable = false}) {
    t.state = TransferState.failed;
    t.errorCode = code;
    t.errorMessage = message;
  }

  Duration _backoff(int attempt) => Duration(seconds: 1 << (attempt - 1));

  int _counter = 0;
  String _id() => '${DateTime.now().microsecondsSinceEpoch}-${_counter++}';

  void _persist() {
    if (_saveScheduled) return;
    _saveScheduled = true;
    scheduleMicrotask(() async {
      _saveScheduled = false;
      try {
        await _store.writeAsString(
            jsonEncode(_queue.map((t) => t.toJson()).toList()));
      } catch (_) {}
    });
  }
}
