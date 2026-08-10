import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:elyxr/api/api_error.dart';
import 'package:elyxr/api/local_trove_client.dart';
import 'package:elyxr/api/lymnal_client.dart';

LymnalClient clientReturning(
  int status,
  Object body, {
  String token = 'tok',
}) {
  final mock = MockClient((req) async => http.Response(
        body is String ? body : jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
      ));
  return LymnalClient(baseUrl: 'http://x:7749', token: token, httpClient: mock);
}

void main() {
  test('list parses a page', () async {
    final c = clientReturning(200, {
      'path': 'music',
      'entries': [
        {'name': 'albums', 'kind': 'dir', 'size_bytes': 0, 'mtime': 1, 'mime': null, 'child_count': 9},
        {'name': 'cover.jpg', 'kind': 'file', 'size_bytes': 284120, 'mtime': 2, 'mime': 'image/jpeg', 'child_count': null},
      ],
      'next_cursor': 'abc',
      'used_bytes': 123,
      'warnings': [],
    });
    final page = await c.list(path: 'music');
    expect(page.entries.length, 2);
    expect(page.entries.first.isDir, isTrue);
    expect(page.entries[1].sizeBytes, 284120);
    expect(page.nextCursor, 'abc');
    expect(page.usedBytes, 123);
  });

  test('a coded error surfaces its message word for word', () async {
    const msg =
        "This file won't fit. Your elyxr folder holds up to 150 GB and it's at 149.1 GB, so this 2.3 GB file is 1.4 GB too big.";
    final c = clientReturning(507, {
      'code': 'TROVE_FULL',
      'message': msg,
      'hint': 'Delete something from elyxr, or raise the limit in elyxr\'s server settings.',
      'request_id': '01J8Z3K7QW',
    });
    try {
      await c.resolve(['big.bin']);
      fail('should have thrown');
    } on LymnalError catch (e) {
      expect(e.code, 'TROVE_FULL');
      expect(e.message, msg); // never reworded
      expect(e.hint, isNotNull);
      expect(e.requestId, '01J8Z3K7QW');
    }
  });

  test('401 reads as no-longer-approved', () async {
    final c = clientReturning(401, {'code': 'TOKEN_REVOKED', 'message': 'x', 'request_id': 'r'});
    expect(
      () => c.list(),
      throwsA(isA<ConnectionError>()
          .having((e) => e.fault, 'fault', ConnectionFault.notApproved)),
    );
  });

  test('a network-unreachable socket reads as no tailnet', () async {
    final mock = MockClient((req) async {
      throw const SocketException('Network is unreachable',
          osError: OSError('Network is unreachable', 101));
    });
    final c = LymnalClient(baseUrl: 'http://x:7749', token: 't', httpClient: mock);
    expect(
      () => c.list(),
      throwsA(isA<ConnectionError>()
          .having((e) => e.fault, 'fault', ConnectionFault.noTailnet)),
    );
  });

  test('a refused connection reads as unreachable', () async {
    final mock = MockClient((req) async {
      throw const SocketException('Connection refused',
          osError: OSError('Connection refused', 111));
    });
    final c = LymnalClient(baseUrl: 'http://x:7749', token: 't', httpClient: mock);
    expect(
      () => c.health(),
      throwsA(isA<ConnectionError>()
          .having((e) => e.fault, 'fault', ConnectionFault.unreachable)),
    );
  });

  // What the music player opens instead of downloading a whole file first: over
  // the network it's the download URL, and it MUST carry the bearer token, since
  // /v1/download rejects an unauthenticated request.
  test('a media source over the network is the download URL, with auth',
      () async {
    final c = LymnalClient(baseUrl: 'http://x:7749', token: 'lym_abc');
    final (uri, headers) = c.mediaSource('music/song.mp3');
    expect(uri, startsWith('http://x:7749/v1/download?'));
    expect(uri, contains('path=music%2Fsong.mp3'));
    expect(headers?['Authorization'], 'Bearer lym_abc');
  });

  test('there is no local path for a trove across the network', () {
    final c = LymnalClient(baseUrl: 'http://x:7749', token: 't');
    expect(c.localPathFor('music/song.mp3'), isNull);
  });

  // On the server device the file is right here, so the player opens it straight
  // off the disk — no URL, no auth header, nothing fetched.
  test('a local trove hands back the file itself, unauthenticated', () {
    final root = Directory.systemTemp.createTempSync('elyxr_trove_test');
    addTearDown(() => root.deleteSync(recursive: true));
    final c = LocalTroveClient(root.path);
    final (uri, headers) = c.mediaSource('music/song.mp3');
    expect(uri, '${root.path}/music/song.mp3');
    expect(headers, isNull);
    expect(c.localPathFor('music/song.mp3'), '${root.path}/music/song.mp3');
  });

  test('a local trove refuses to hand out a path that climbs out of it', () {
    final root = Directory.systemTemp.createTempSync('elyxr_trove_esc');
    addTearDown(() => root.deleteSync(recursive: true));
    final c = LocalTroveClient(root.path);
    expect(c.localPathFor('../../etc/passwd'), isNull);
  });
}
