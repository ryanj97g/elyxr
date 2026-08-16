// Switching to a local folder must not cost you the server. The pairing, the
// token and the remembered address stay exactly as they were, and switching back
// reconnects without asking for anything.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:elyxr/api/local_trove_client.dart';
import 'package:elyxr/api/lymnal_client.dart';
import 'package:elyxr/state/session.dart';

http.Client _server() => MockClient((req) async {
      if (req.url.path == '/v1/health') {
        return http.Response(
          jsonEncode({
            'version': '1.0.0',
            'uptime_s': 1,
            'trove': 'elyxr',
            'used_bytes': 1,
            'max_bytes': 2,
            'drive_free_bytes': 3,
            'pairing_open': false,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 200,
          headers: {'content-type': 'application/json'});
    });

Future<SessionController> paired() async {
  SessionController.sandboxHome =
      Directory.systemTemp.createTempSync('elyxr_local_mode').path;
  SharedPreferences.setMockInitialValues({
    'serverAddress': '100.0.0.9:7749',
    'serverName': '100.0.0.9',
  });
  final prefs = await SharedPreferences.getInstance();
  final s = SessionController(
    prefs,
    MemoryTokenStore('tok'),
    factory: (baseUrl, {token}) =>
        LymnalClient(baseUrl: baseUrl, token: token, httpClient: _server()),
  );
  await s.boot();
  return s;
}

void main() {
  tearDown(() => SessionController.sandboxHome = null);

  test('going local keeps the pairing intact', () async {
    final s = await paired();
    expect(s.serverAddress, '100.0.0.9:7749');

    s.useLocalTrove('/tmp/some/folder');
    expect(s.client, isA<LocalTroveClient>(),
        reason: 'the browser should be reading the folder');
    expect(s.serverAddress, '100.0.0.9:7749',
        reason: 'the saved server must survive the switch');
    expect(s.isFirstRun, isFalse,
        reason: 'going local must never look like an unpaired device');
  });

  test('coming back restores the server, name and all', () async {
    final s = await paired();
    final nameBefore = s.serverName;

    s.useLocalTrove('/tmp/some/folder');
    expect(s.serverName, 'folder', reason: 'local shows the folder');

    s.useRemote();
    expect(s.client, isNot(isA<LocalTroveClient>()));
    expect(s.serverName, nameBefore,
        reason: 'the server got its name back, not the folder name');
    expect(s.serverAddress, '100.0.0.9:7749');
  });

  test('a round trip changes nothing that was saved', () async {
    final s = await paired();
    final addr = s.serverAddress;
    for (var i = 0; i < 3; i++) {
      s.useLocalTrove('/tmp/f$i');
      s.useRemote();
    }
    expect(s.serverAddress, addr);
    expect(s.isFirstRun, isFalse);
  });
}
