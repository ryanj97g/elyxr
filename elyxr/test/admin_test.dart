import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:elyxr/api/admin_client.dart';
import 'package:elyxr/state/server.dart';

AdminClient clientFor(Map<String, Object> routes) {
  final mock = MockClient((req) async {
    final body = routes[req.url.path];
    if (body == null) return http.Response('{}', 404);
    return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
  });
  return AdminClient(baseUrl: 'http://x:7749', adminToken: 'adm', httpClient: mock);
}

void main() {
  test('admin token rides in the header', () async {
    String? seen;
    final mock = MockClient((req) async {
      seen = req.headers['X-Admin-Token'];
      return http.Response(jsonEncode({'running': true, 'version': '1.0.0'}), 200,
          headers: {'content-type': 'application/json'});
    });
    final c = AdminClient(baseUrl: 'http://x:7749', adminToken: 'adm-secret', httpClient: mock);
    await c.status();
    expect(seen, 'adm-secret');
  });

  test('pending, devices, and space parse', () async {
    final c = clientFor({
      '/v1/admin/pending': {
        'pending': [
          {'device': 'laptop', 'client': 'elyxr/1.0.0', 'phrase': 'violet anchor cedar juniper'}
        ]
      },
      '/v1/admin/devices': {
        'devices': [
          {'label': 'probookrjg', 'role': 'owner', 'max_bytes': 150000000000, 'approved_at': 1, 'last_seen': 2}
        ]
      },
      '/v1/admin/space': {
        'used_bytes': 68400000000,
        'drive_free_bytes': 62400000000,
        'max_bytes': 150000000000,
        'warn_at_bytes': 100000000000,
        'warn_every': 5000000000,
        'min_free_bytes': 15000000000,
      },
    });
    final pending = await c.pending();
    expect(pending.single.device, isNotEmpty);
    final devices = await c.devices();
    expect(devices.single.role, 'owner');
    final space = await c.space();
    expect(space.maxBytes, 150000000000);
  });

  test('the controller loads state and surfaces it', () async {
    final c = clientFor({
      '/v1/admin/status': {'running': true, 'version': '1.0.0', 'uptime_s': 10, 'bind': 'x:7749', 'trove': 'elyxr', 'pairing_open': true},
      '/v1/admin/pending': {'pending': []},
      '/v1/admin/devices': {'devices': []},
      '/v1/admin/space': {'used_bytes': 1, 'drive_free_bytes': 2, 'max_bytes': 3, 'warn_at_bytes': 4, 'warn_every': 5, 'min_free_bytes': 6},
      '/v1/admin/problems': {'problems': []},
    });
    final ctl = ServerController();
    ctl.connect(c);
    // connect() kicks off refresh; wait for it.
    await Future.delayed(const Duration(milliseconds: 50));
    expect(ctl.available, isTrue);
    expect(ctl.status?.running, isTrue);
    expect(ctl.status?.pairingOpen, isTrue);
    expect(ctl.error, isNull);
  });
}
