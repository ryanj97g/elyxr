import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:elyxr/api/lymnal_client.dart';
import 'package:elyxr/state/browse.dart';
import 'package:elyxr/state/session.dart';

/// A tiny fake lymnal that serves a couple of folders with paging and search.
http.Client fakeServer() {
  return MockClient((req) async {
    final path = req.url.path;
    final q = req.url.queryParameters;
    Map<String, dynamic> ok(Object body) => body as Map<String, dynamic>;

    if (path == '/v1/health') {
      return http.Response(
        jsonEncode({
          'version': '1.0.0',
          'uptime_s': 1,
          'trove': 'elyxr',
          'used_bytes': 68400000000,
          'max_bytes': 150000000000,
          'drive_free_bytes': 62400000000,
          'pairing_open': false,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }

    if (path == '/v1/list') {
      final folder = q['path'] ?? '';
      if (folder == '') {
        return _json({
          'path': '',
          'entries': [
            _dir('music', 3),
            _dir('photos', 2),
            _file('notes.txt', 2048),
          ],
          'next_cursor': null,
          'used_bytes': 68400000000,
          'warnings': [],
        });
      }
      if (folder == 'big') {
        if (q['cursor'] == null) {
          return _json({
            'path': 'big',
            'entries': [_file('a.bin', 1), _file('b.bin', 1)],
            'next_cursor': 'p2',
            'used_bytes': 1,
            'warnings': [],
          });
        }
        return _json({
          'path': 'big',
          'entries': [_file('c.bin', 1)],
          'next_cursor': null,
          'used_bytes': 1,
          'warnings': [],
        });
      }
      ok; // silence unused
      return _json({'path': folder, 'entries': [], 'next_cursor': null, 'used_bytes': 0, 'warnings': []});
    }

    if (path == '/v1/search') {
      return _json({
        'results': [
          {'path': 'music/albums/Kind of Blue', 'kind': 'dir', 'size_bytes': 0, 'mtime': 1},
        ],
        'truncated': false,
        'reason': null,
      });
    }

    return http.Response('{"code":"NOT_FOUND","message":"x","request_id":"r"}', 404,
        headers: {'content-type': 'application/json'});
  });
}

http.Response _json(Object body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
Map<String, dynamic> _dir(String name, int children) =>
    {'name': name, 'kind': 'dir', 'size_bytes': 0, 'mtime': 1, 'mime': null, 'child_count': children};
Map<String, dynamic> _file(String name, int size) =>
    {'name': name, 'kind': 'file', 'size_bytes': size, 'mtime': 1, 'mime': null, 'child_count': null};

Future<SessionController> connectedSession() async {
  SharedPreferences.setMockInitialValues({
    'serverAddress': 'x:7749',
    'serverName': 'x',
  });
  final prefs = await SharedPreferences.getInstance();
  final mock = fakeServer();
  final session = SessionController(
    prefs,
    MemoryTokenStore('tok'),
    factory: (baseUrl, {token}) =>
        LymnalClient(baseUrl: baseUrl, token: token, httpClient: mock),
  );
  await session.boot();
  return session;
}

void main() {
  test('boot connects and health arrives', () async {
    final session = await connectedSession();
    expect(session.status, LinkStatus.ok);
    expect(session.isFirstRun, isFalse);
    expect(session.health!.maxBytes, 150000000000);
  });

  test('open root lists entries, folders parsed', () async {
    final b = BrowseController(await connectedSession());
    await b.open('');
    expect(b.state, FolderState.ready);
    expect(b.entries.length, 3);
    expect(b.entries.first.isDir, isTrue);
    expect(b.entries.first.childCount, 3);
  });

  test('paging appends without repeats', () async {
    final b = BrowseController(await connectedSession());
    await b.open('big');
    expect(b.entries.map((e) => e.name), ['a.bin', 'b.bin']);
    expect(b.hasMore, isTrue);
    await b.loadMore();
    expect(b.entries.map((e) => e.name), ['a.bin', 'b.bin', 'c.bin']);
    expect(b.hasMore, isFalse);
  });

  test('navigation: into a folder, back, and up', () async {
    final b = BrowseController(await connectedSession());
    await b.open('');
    await b.open('music');
    expect(b.path, 'music');
    expect(b.canGoBack, isTrue);
    await b.goBack();
    expect(b.path, '');
    await b.open('music');
    await b.goUp();
    expect(b.path, '');
  });

  test('selection toggles and clears on leaving the folder', () async {
    final b = BrowseController(await connectedSession());
    await b.open('');
    b.toggle(2); // notes.txt
    expect(b.hasSelection, isTrue);
    expect(b.selectionPaths, ['notes.txt']);
    await b.open('music'); // leaving clears
    expect(b.hasSelection, isFalse);
  });

  test('search populates results and a hit navigates', () async {
    final b = BrowseController(await connectedSession());
    await b.open('');
    await b.setQuery('blue');
    expect(b.searchResult, isNotNull);
    expect(b.searchResult!.results.length, 1);
    await b.openHit(b.searchResult!.results.first);
    expect(b.path, 'music/albums');
    expect(b.markedEntry, 'Kind of Blue');
  });

  test('cycleSort moves NAME -> SIZE -> DATE', () async {
    final b = BrowseController(await connectedSession());
    await b.open('');
    expect(b.sort, SortKey.name);
    await b.cycleSort();
    expect(b.sort, SortKey.size);
    await b.cycleSort();
    expect(b.sort, SortKey.mtime);
  });
}
