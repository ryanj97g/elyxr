// A server that moves on the tailnet is handed a new number, and every paired
// device is left pointing at one that answers to nothing. The cure is to pair
// with the name the server has on the tailnet, since a name follows the machine.
// These cover the saving of that name, and correcting an address by hand without
// losing the pairing.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:elyxr/api/lymnal_client.dart';
import 'package:elyxr/api/models.dart';
import 'package:elyxr/state/session.dart';

/// A stand-in server. [host] is what it calls itself on the tailnet; null is an
/// older server that has never heard of the idea.
http.Client _server({String? host}) => MockClient((req) async {
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
            if (host != null) 'host': host,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 200,
          headers: {'content-type': 'application/json'});
    });

Future<SessionController> paired({
  String? reports,
  String address = '100.0.0.9:7749',
  String? savedHost,
}) async {
  SessionController.sandboxHome =
      Directory.systemTemp.createTempSync('elyxr_server_name').path;
  SharedPreferences.setMockInitialValues({
    'serverAddress': address,
    'serverName': address.split(':').first,
    if (savedHost != null) 'serverHost': savedHost,
  });
  final prefs = await SharedPreferences.getInstance();
  final s = SessionController(
    prefs,
    MemoryTokenStore('tok'),
    factory: (baseUrl, {token}) => LymnalClient(
        baseUrl: baseUrl, token: token, httpClient: _server(host: reports)),
  );
  await s.boot();
  return s;
}

void main() {
  tearDown(() => SessionController.sandboxHome = null);

  test('health carries the name the server has on the tailnet', () {
    final h = Health.fromJson({
      'version': '1.0.0',
      'host': 'ryang5mini.tail182ffa.ts.net',
    });
    expect(h.host, 'ryang5mini.tail182ffa.ts.net');
  });

  test('a blank name is no name at all', () {
    expect(Health.fromJson({'host': '  '}).host, isNull);
    expect(Health.fromJson(const {}).host, isNull);
  });

  test('a device paired to a number adopts the name on connecting', () async {
    final s = await paired(reports: 'ryang5mini.tail182ffa.ts.net');
    expect(s.serverHost, 'ryang5mini.tail182ffa.ts.net:7749',
        reason: 'the name is kept on the port we were already talking on');
    expect(s.displayAddress, 'ryang5mini.tail182ffa.ts.net:7749',
        reason: 'the name is what to show, being the durable half');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('serverHost'), 'ryang5mini.tail182ffa.ts.net:7749',
        reason: 'and it survives a restart');
  });

  test('an older server that reports no name leaves the pairing alone',
      () async {
    final s = await paired();
    expect(s.serverHost, isNull);
    expect(s.displayAddress, '100.0.0.9:7749',
        reason: 'nothing to prefer, so the number still shows');
  });

  test('a non-default port is carried into the name', () async {
    final s = await paired(
        address: '100.0.0.9:9999', reports: 'ryang5mini.tail182ffa.ts.net');
    expect(s.serverHost, 'ryang5mini.tail182ffa.ts.net:9999');
  });

  test('correcting the address by hand keeps the pairing', () async {
    final s = await paired();
    await s.setAddress('100.0.0.77:7749');
    expect(s.serverAddress, '100.0.0.77:7749');
    expect(s.bearerToken, 'tok',
        reason: 'the token is the server\'s, not the address\'s');
    expect(s.isFirstRun, isFalse,
        reason: 'a corrected address must never look like an unpaired device');
  });

  test('a bare name typed by hand gets the port filled in', () async {
    final s = await paired();
    await s.setAddress('not-a-real-machine-xyz');
    expect(s.serverAddress, 'not-a-real-machine-xyz:7749');
    expect(s.serverHost, 'not-a-real-machine-xyz:7749',
        reason: 'a name is kept as the durable half of the pairing');
  });

  test('a name that does not resolve leaves the last known number in place',
      () async {
    final s = await paired(savedHost: 'not-a-real-machine-xyz:7749');
    expect(s.serverAddress, '100.0.0.9:7749',
        reason: 'a failed lookup must not throw away the only address we have');
  });

  test('forgetting the server forgets its name too', () async {
    final s = await paired(reports: 'ryang5mini.tail182ffa.ts.net');
    expect(s.serverHost, isNotNull);
    await s.forget();
    expect(s.serverHost, isNull);
    expect(s.displayAddress, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('serverHost'), isNull);
  });
}
