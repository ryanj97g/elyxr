// The one way the app talks to lymnal (§04). JSON over HTTP/1.1, a bearer token
// on everything except health and pair. Every failure comes back as either a
// [LymnalError] (the server answered with a coded body) or a [ConnectionError]
// (the request never arrived).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'api_error.dart';
import 'models.dart';

/// The token and role handed back once at pairing.
class PairResult {
  final String token;
  final String label;
  final String role;
  final int maxBytes;
  const PairResult({
    required this.token,
    required this.label,
    required this.maxBytes,
    required this.role,
  });

  factory PairResult.fromJson(Map<String, dynamic> j) => PairResult(
        token: j['token'] as String,
        label: j['label'] as String? ?? '',
        role: j['role'] as String? ?? 'owner',
        maxBytes: (j['max_bytes'] as num?)?.toInt() ?? 0,
      );
}

class LymnalClient {
  /// Base like `http://100.x.y.z:7749` (the server's tailnet address).
  final String baseUrl;
  final String? token;
  final http.Client _http;
  final Duration timeout;

  LymnalClient({
    required this.baseUrl,
    this.token,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 6),
  }) : _http = httpClient ?? http.Client();

  /// A copy of this client carrying a token (after pairing).
  LymnalClient withToken(String token) => LymnalClient(
        baseUrl: baseUrl,
        token: token,
        httpClient: _http,
        timeout: timeout,
      );

  void close() => _http.close();

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  Map<String, String> _headers({bool json = false}) => {
        if (token != null) 'Authorization': 'Bearer $token',
        if (json) 'Content-Type': 'application/json',
      };

  // ---- endpoints ----

  Future<Health> health() async {
    // Health is used for discovery too, so give it a shorter fuse.
    final r = await _send(() => _http
        .get(_uri('/v1/health'), headers: _headers())
        .timeout(const Duration(seconds: 3)));
    return Health.fromJson(_ok(r));
  }

  Future<PairResult> pair(String device, String client) async {
    // Pairing blocks until a person approves (up to 120s), so it needs a long
    // fuse of its own rather than the default request timeout.
    final r = await _send(
      () => _http
          .post(
            _uri('/v1/pair'),
            headers: _headers(json: true),
            body: jsonEncode({'device': device, 'client': client}),
          )
          .timeout(const Duration(seconds: 130)),
    );
    return PairResult.fromJson(_ok(r));
  }

  Future<ListPage> list({
    String path = '',
    String sort = 'name',
    String order = 'asc',
    int limit = 500,
    String? cursor,
  }) async {
    final r = await _send(() => _http.get(
          _uri('/v1/list', {
            'path': path,
            'sort': sort,
            'order': order,
            'limit': '$limit',
            if (cursor != null) 'cursor': cursor,
          }),
          headers: _headers(),
        ));
    return ListPage.fromJson(_ok(r));
  }

  Future<Entry> stat(String path) async {
    final r = await _send(
        () => _http.get(_uri('/v1/stat', {'path': path}), headers: _headers()));
    return Entry.fromJson(_ok(r));
  }

  Future<SearchResult> search(String q, {String path = '', int limit = 200}) async {
    final r = await _send(() => _http.get(
          _uri('/v1/search', {'q': q, 'path': path, 'limit': '$limit'}),
          headers: _headers(),
        ));
    return SearchResult.fromJson(_ok(r));
  }

  Future<ResolveResult> resolve(List<String> paths) async {
    final r = await _send(() => _http.post(
          _uri('/v1/resolve'),
          headers: _headers(json: true),
          body: jsonEncode({'paths': paths}),
        ));
    return ResolveResult.fromJson(_ok(r));
  }

  Future<Map<String, dynamic>> move(String from, String to,
      {String onConflict = 'fail'}) async {
    final r = await _send(() => _http.post(
          _uri('/v1/move'),
          headers: _headers(json: true),
          body: jsonEncode({'from': from, 'to': to, 'on_conflict': onConflict}),
        ));
    return _ok(r);
  }

  Future<Map<String, dynamic>> delete(List<String> paths) async {
    final r = await _send(() => _http.post(
          _uri('/v1/delete'),
          headers: _headers(json: true),
          body: jsonEncode({'paths': paths}),
        ));
    return _ok(r);
  }

  Future<Map<String, dynamic>> mkdir(String path) async {
    final r = await _send(() => _http.post(
          _uri('/v1/mkdir'),
          headers: _headers(json: true),
          body: jsonEncode({'path': path}),
        ));
    return _ok(r);
  }

  // ---- uploads (§04, §05) ----

  Future<UploadSession> uploadInit(String path, int sizeBytes,
      {String? checksum, int? mtime}) async {
    final r = await _send(() => _http.post(
          _uri('/v1/upload/init'),
          headers: _headers(json: true),
          body: jsonEncode({
            'path': path,
            'size_bytes': sizeBytes,
            if (checksum != null) 'checksum': checksum,
            if (mtime != null) 'mtime': mtime,
          }),
        ));
    return UploadSession.fromJson(_ok(r));
  }

  /// Send one chunk at [offset]. Idempotent per offset. Returns (received, done).
  Future<(int, bool)> uploadChunk(
      String id, int offset, List<int> bytes, int total) async {
    final end = offset + bytes.length - 1;
    final r = await _send(() => _http.put(
          _uri('/v1/upload/$id'),
          headers: {
            ..._headers(),
            'Content-Range': 'bytes $offset-$end/$total',
            'Content-Type': 'application/octet-stream',
          },
          body: bytes,
        ));
    final j = _ok(r);
    return ((j['received_bytes'] as num).toInt(), j['complete'] as bool? ?? false);
  }

  /// Progress for resume: (received, size, missing ranges, expiresAt).
  Future<(int, int, List<List<int>>, int)> uploadStatus(String id) async {
    final r = await _send(() => _http.get(_uri('/v1/upload/$id'), headers: _headers()));
    final j = _ok(r);
    final missing = (j['missing'] as List? ?? [])
        .map((e) => (e as List).map((n) => (n as num).toInt()).toList())
        .toList();
    return (
      (j['received_bytes'] as num).toInt(),
      (j['size_bytes'] as num).toInt(),
      missing,
      (j['expires_at'] as num?)?.toInt() ?? 0,
    );
  }

  Future<Map<String, dynamic>> uploadCommit(String id) async {
    final r = await _send(() => _http.post(_uri('/v1/upload/$id/commit'),
        headers: _headers(json: true), body: '{}'));
    return _ok(r);
  }

  Future<void> uploadCancel(String id) async {
    await _send(() => _http.delete(_uri('/v1/upload/$id'), headers: _headers()));
  }

  // ---- downloads (§04, §05) ----

  /// Stream a file to disk, appending from [resumeFrom] with a Range request so
  /// an interrupted download resumes rather than restarts. Reports bytes as
  /// they land. Returns the total size written.
  Future<void> downloadTo(
    String path,
    IOSink sink, {
    int resumeFrom = 0,
    void Function(int received)? onBytes,
    bool Function()? cancelled,
  }) async {
    final req = http.Request('GET', _uri('/v1/download', {'path': path}));
    req.headers.addAll(_headers());
    if (resumeFrom > 0) req.headers['Range'] = 'bytes=$resumeFrom-';
    final streamed = await _sendStreamed(req);
    if (streamed.statusCode == 401) {
      throw const ConnectionError(ConnectionFault.notApproved);
    }
    if (streamed.statusCode >= 400) {
      final body = await streamed.stream.bytesToString();
      _throwCoded(body, streamed.statusCode);
    }
    var received = resumeFrom;
    await for (final chunk in streamed.stream) {
      if (cancelled?.call() ?? false) break;
      sink.add(chunk);
      received += chunk.length;
      onBytes?.call(received);
    }
  }

  /// Stream a zip of [paths] to disk.
  Future<void> zipTo(List<String> paths, String name, IOSink sink,
      {bool Function()? cancelled, void Function(int received)? onBytes}) async {
    final req = http.Request('POST', _uri('/v1/zip'));
    req.headers.addAll(_headers(json: true));
    req.body = jsonEncode({'paths': paths, 'name': name});
    final streamed = await _sendStreamed(req);
    if (streamed.statusCode >= 400) {
      final body = await streamed.stream.bytesToString();
      if (streamed.statusCode == 401) {
        throw const ConnectionError(ConnectionFault.notApproved);
      }
      _throwCoded(body, streamed.statusCode);
    }
    var received = 0;
    await for (final chunk in streamed.stream) {
      if (cancelled?.call() ?? false) break;
      sink.add(chunk);
      received += chunk.length;
      onBytes?.call(received);
    }
  }

  /// Fetch a whole file into memory — for preview of images (§07). Large files
  /// are the queue's job, not this.
  Future<List<int>> downloadBytes(String path) async {
    final r = await _send(
        () => _http.get(_uri('/v1/download', {'path': path}), headers: _headers()));
    if (r.statusCode == 401) {
      throw const ConnectionError(ConnectionFault.notApproved);
    }
    if (r.statusCode >= 400) _throwCoded(r.body, r.statusCode);
    return r.bodyBytes;
  }

  // ---- events (§04) ----

  /// Subscribe to the change stream. Yields decoded `change` and `usage`
  /// events; pings are swallowed. The stream ends if the connection drops.
  Stream<ServerEvent> events({String? lastEventId}) async* {
    final req = http.Request('GET', _uri('/v1/events'));
    req.headers.addAll(_headers());
    req.headers['Accept'] = 'text/event-stream';
    if (lastEventId != null) req.headers['Last-Event-ID'] = lastEventId;
    final streamed = await _sendStreamed(req);
    if (streamed.statusCode >= 400) {
      throw const ConnectionError(ConnectionFault.unreachable);
    }
    String event = 'message';
    String? id;
    await for (final line
        in streamed.stream.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.isEmpty) {
        event = 'message';
        continue;
      }
      if (line.startsWith('event:')) {
        event = line.substring(6).trim();
      } else if (line.startsWith('id:')) {
        id = line.substring(3).trim();
      } else if (line.startsWith('data:')) {
        final data = line.substring(5).trim();
        if (event == 'ping') continue;
        try {
          final json = (jsonDecode(data) as Map).cast<String, dynamic>();
          yield ServerEvent(event: event, id: id, data: json);
        } catch (_) {
          // Ignore an unparseable line rather than tear down the stream.
        }
      }
    }
  }

  Future<http.StreamedResponse> _sendStreamed(http.BaseRequest req) async {
    try {
      return await _http.send(req);
    } on SocketException catch (e) {
      final errno = e.osError?.errorCode;
      if (errno == 101 || e.message.toLowerCase().contains('network is unreachable')) {
        throw const ConnectionError(ConnectionFault.noTailnet);
      }
      throw const ConnectionError(ConnectionFault.unreachable);
    } on http.ClientException {
      throw const ConnectionError(ConnectionFault.unreachable);
    }
  }

  Never _throwCoded(String body, int status) {
    Map<String, dynamic> j;
    try {
      j = (jsonDecode(body) as Map).cast<String, dynamic>();
    } catch (_) {
      j = {'code': 'IO_ERROR', 'message': 'The server sent an unreadable error.'};
    }
    throw LymnalError.fromJson(j, status);
  }

  // ---- plumbing ----

  /// Run a request, turning the network faults lymnal can't report into a
  /// [ConnectionError] with the right fault.
  Future<http.Response> _send(Future<http.Response> Function() run) async {
    try {
      return await run();
    } on TimeoutException {
      throw const ConnectionError(ConnectionFault.unreachable);
    } on SocketException catch (e) {
      // ENETUNREACH (network is unreachable) reads as the tailnet being down;
      // a refused/reset/host-unreachable connection reads as the server asleep.
      final errno = e.osError?.errorCode;
      if (errno == 101 || (e.message.toLowerCase().contains('network is unreachable'))) {
        throw const ConnectionError(ConnectionFault.noTailnet);
      }
      throw const ConnectionError(ConnectionFault.unreachable);
    } on http.ClientException {
      throw const ConnectionError(ConnectionFault.unreachable);
    }
  }

  /// Decode a 2xx body, or throw the coded error. A 401 is the "no longer
  /// approved" state (§11), raised as a [ConnectionError] so the app can offer
  /// to ask for access again.
  Map<String, dynamic> _ok(http.Response r) {
    if (r.statusCode >= 200 && r.statusCode < 300) {
      if (r.body.isEmpty) return const {};
      return (jsonDecode(r.body) as Map).cast<String, dynamic>();
    }
    if (r.statusCode == 401) {
      throw const ConnectionError(ConnectionFault.notApproved);
    }
    Map<String, dynamic> body;
    try {
      body = (jsonDecode(r.body) as Map).cast<String, dynamic>();
    } catch (_) {
      body = {'code': 'IO_ERROR', 'message': 'The server sent an unreadable error.'};
    }
    throw LymnalError.fromJson(body, r.statusCode);
  }
}
