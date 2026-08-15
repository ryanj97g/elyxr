// The suite must never write to the machine it runs on.
//
// boot() calls _syncLink(), which writes ~/.config/lymnal/link.json — the file
// the lymnal service reads to know which server this device is paired to — and
// then restarts the service. Run unsandboxed on a paired device, a test would
// replace the real pairing with its own mocked one and bounce the service, so
// the app went quiet with nothing to say why. This pins the sandbox shut.

import 'dart:convert';
import 'dart:io';

import 'package:elyxr/state/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  tearDown(() => SessionController.sandboxHome = null);

  test('boot writes its pairing inside the sandbox, not the real home', () async {
    final sandbox = Directory.systemTemp.createTempSync('elyxr_sandbox');
    SessionController.sandboxHome = sandbox.path;
    SharedPreferences.setMockInitialValues({
      'serverAddress': 'x:7749',
      'serverName': 'x',
    });
    final prefs = await SharedPreferences.getInstance();
    final session = SessionController(prefs, MemoryTokenStore('tok'));
    await session.boot();

    final written = File('${sandbox.path}/.config/lymnal/link.json');
    expect(written.existsSync(), isTrue,
        reason: 'the pairing should land in the sandbox');
    final j = jsonDecode(written.readAsStringSync()) as Map<String, dynamic>;
    expect(j['server'], 'x:7749');
  });

  test('the real home is never consulted while sandboxed', () async {
    final sandbox = Directory.systemTemp.createTempSync('elyxr_sandbox');
    SessionController.sandboxHome = sandbox.path;
    // If the sandbox were ignored, this is the file that would be clobbered.
    final home = Platform.environment['HOME'];
    final real = home == null ? null : File('$home/.config/lymnal/link.json');
    final before = (real != null && real.existsSync())
        ? real.readAsStringSync()
        : null;

    SharedPreferences.setMockInitialValues({
      'serverAddress': 'somewhere-else:7749',
      'serverName': 'somewhere-else',
    });
    final prefs = await SharedPreferences.getInstance();
    await SessionController(prefs, MemoryTokenStore('tok2')).boot();

    final after = (real != null && real.existsSync())
        ? real.readAsStringSync()
        : null;
    expect(after, before,
        reason: 'the real pairing file must be byte-identical afterwards');
  });
}
