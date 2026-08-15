// The server screen's controls, tapped for real.
//
// Two separate things made the PAIRING button look broken, and only one of them
// was about the button:
//
//  1. Every control was a GestureDetector wrapped straight round a Text, with no
//     behavior and no padding. deferToChild means the only hittable region is the
//     glyph box — an 11px strip of small caps. A press a few pixels off missed.
//
//  2. _guard caught only LymnalError. Anything else — a connection fault, a
//     timeout, a 2xx that wasn't JSON — escaped uncaught, so the press did
//     nothing, showed nothing and changed nothing.
//
// The second is the one that matters: a control whose action fails invisibly is
// indistinguishable from a dead control, and it made EVERY button on this screen
// appear dead whenever the local service was unreachable. So these tests press
// the real widget and check that something always comes back.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:elyxr/api/admin_client.dart';
import 'package:elyxr/design/tokens.dart';
import 'package:elyxr/state/session.dart';
import 'package:elyxr/screens/server_view.dart';
import 'package:elyxr/state/server.dart';
import 'package:elyxr/state/settings.dart';
import 'package:elyxr/state/updater.dart';

const _status = {
  'running': true,
  'version': '0.9.0',
  'build': 317,
  'uptime_s': 60,
  'bind': '100.1.2.3:7749',
  'pairing_open': false,
  'trove_path': '/home/x/Desktop/trove',
};

/// An admin client whose responses are scripted per path.
AdminClient _client({
  required Map<String, String> ok,
  Object? throwOn,
  String? throwPath,
  List<String>? seen,
}) {
  final mock = MockClient((req) async {
    seen?.add('${req.method} ${req.url.path}');
    if (throwPath != null && req.url.path == throwPath && throwOn != null) {
      if (throwOn is Exception) throw throwOn;
      // A 200 whose body isn't JSON — a proxy or sign-in page answering.
      return http.Response(throwOn as String, 200);
    }
    final body = ok[req.url.path];
    if (body == null) return http.Response('{}', 200);
    return http.Response(body, 200);
  });
  return AdminClient(
      baseUrl: 'http://x:7749', adminToken: 't', httpClient: mock);
}

Future<Widget> _screen(ServerController server) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final prefs = await SharedPreferences.getInstance();
  // The updater listens to the session for the server's update announcement, so
  // it needs one; this screen never exercises either, so an unbooted session is
  // enough to build the tree.
  final session = SessionController(prefs, MemoryTokenStore(null));
  return MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: server),
      ChangeNotifierProvider.value(value: SettingsController(prefs)),
      ChangeNotifierProvider(create: (_) => UpdateController(session)),
    ],
    child: MaterialApp(
      home: Material(
        child: SingleChildScrollView(
          child: ServerControls(palette: Palette(Accent.green, true)),
        ),
      ),
    ),
  );
}

void main() {
  // The bug that made the PAIRING button dead on Windows for builds 313-319.
  //
  // The Windows window gives the tube 440 logical pixels of width; Linux gives
  // 552. At 440 the rows on this screen overflowed horizontally, and a Row with
  // nothing flexible in it pushes its last child straight past its own right
  // edge. Flutter's RenderBox.hitTest starts with `if (size.contains(position))`,
  // so a child sitting outside its parent is painted and never hit — a button you
  // can see and cannot press. Nothing about the button was wrong; it was outside
  // the box holding it.
  testWidgets('nothing overflows at the Windows window width', (tester) async {
    tester.view.physicalSize = const Size(440, 882);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final server = ServerController();
    server.connect(_client(ok: {
      '/v1/admin/status': jsonEncode(_status),
      '/v1/admin/pending': jsonEncode({'pending': []}),
      '/v1/admin/devices': jsonEncode({'devices': []}),
      '/v1/admin/space': jsonEncode({
        'used_bytes': 1,
        'max_bytes': 2,
        'warn_at_bytes': 1,
        'min_free_bytes': 1
      }),
    }));
    await tester.pumpWidget(await _screen(server));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull,
        reason: 'a row overflowed, so whatever it pushed out is unpressable');
  });

  final okPaths = {
    '/v1/admin/status': jsonEncode(_status),
    '/v1/admin/pending': jsonEncode({'pending': []}),
    '/v1/admin/devices': jsonEncode({'devices': []}),
    '/v1/admin/space': jsonEncode(
        {'used_bytes': 1, 'max_bytes': 2, 'warn_at_bytes': 1, 'min_free_bytes': 1}),
  };

  testWidgets('the pairing control is reachable and fires', (tester) async {
    final seen = <String>[];
    final server = ServerController();
    server.connect(_client(ok: okPaths, seen: seen));
    await tester.pumpWidget(await _screen(server));
    await tester.pumpAndSettle();

    final label = find.text('OFF — OPEN');
    expect(label, findsOneWidget, reason: 'the pairing control is not on screen');

    // Press the padding, NOT the glyphs: 14px below the label's centre is inside
    // the button and outside the text. Before the fix this landed on nothing,
    // because deferToChild meant only the glyph box could be hit.
    final box = tester.getRect(label);
    await tester.tapAt(Offset(box.center.dx, box.bottom + 4));
    await tester.pumpAndSettle();

    expect(seen, contains('POST /v1/admin/pairing'),
        reason: 'a press just outside the text did not reach the handler');
  });

  testWidgets('the whole control is one target, edge to edge', (tester) async {
    // Every corner of the button must work, not just the middle.
    for (final corner in ['tl', 'tr', 'bl', 'br']) {
      final seen = <String>[];
      final server = ServerController();
      server.connect(_client(ok: okPaths, seen: seen));
      await tester.pumpWidget(await _screen(server));
      await tester.pumpAndSettle();
      final b = tester.getRect(find.text('OFF — OPEN'));
      final at = switch (corner) {
        'tl' => Offset(b.left - 6, b.top - 4),
        'tr' => Offset(b.right + 6, b.top - 4),
        'bl' => Offset(b.left - 6, b.bottom + 4),
        _ => Offset(b.right + 6, b.bottom + 4),
      };
      await tester.tapAt(at);
      await tester.pumpAndSettle();
      expect(seen, contains('POST /v1/admin/pairing'),
          reason: 'the $corner corner of the button is dead');
    }
  });

  // The failures that used to vanish. Each must leave a message on screen: the
  // press has to produce SOMETHING, or the button reads as broken.
  testWidgets('a connection fault says so instead of doing nothing',
      (tester) async {
    final server = ServerController();
    server.connect(_client(
        ok: okPaths,
        throwPath: '/v1/admin/pairing',
        throwOn: const HttpException('connection failed')));
    await tester.pumpWidget(await _screen(server));
    await tester.pumpAndSettle();
    await tester.tapAt(
        tester.getRect(find.text('OFF — OPEN')).center);
    await tester.pumpAndSettle();
    expect(server.error, isNotNull,
        reason: 'the failure was swallowed — the press looked like a no-op');
    expect(server.busy, isFalse, reason: 'left stuck in the busy state');
  });

  testWidgets('a 2xx that is not JSON says so too', (tester) async {
    final server = ServerController();
    server.connect(_client(
        ok: okPaths,
        throwPath: '/v1/admin/pairing',
        throwOn: '<html>sign in</html>'));
    await tester.pumpWidget(await _screen(server));
    await tester.pumpAndSettle();
    await tester.tapAt(tester.getRect(find.text('OFF — OPEN')).center);
    await tester.pumpAndSettle();
    expect(server.error, isNotNull);
    expect(server.busy, isFalse);
  });

  test('an unconnected controller explains itself rather than going quiet', () async {
    final server = ServerController();
    await server.setPairing(true);
    expect(server.error, isNotNull,
        reason: 'not being connected was a silent return');
  });
}

/// A stand-in for a transport failure, thrown from the mock.
class HttpException implements Exception {
  final String message;
  const HttpException(this.message);
  @override
  String toString() => 'HttpException: $message';
}
