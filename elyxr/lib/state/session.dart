// Who this device is paired with, and whether the server can be reached.
//
// The token lives in the system keyring (never in prefs, never on screen). The
// server's address and name are ordinary prefs. First run is simply "no token
// yet" (§08); forgetting a server returns here (§10).

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_error.dart';
import '../api/lymnal_client.dart';
import '../api/models.dart';

/// Where the bearer token is kept. Abstracted so tests can swap the keyring for
/// memory (the keyring needs a desktop secret service that headless CI lacks).
abstract class TokenStore {
  Future<String?> read();
  Future<void> write(String token);
  Future<void> delete();
}

/// The real keyring-backed store (libsecret on Linux).
class KeyringTokenStore implements TokenStore {
  static const _key = 'elyxr.bearer';
  final FlutterSecureStorage _s;
  KeyringTokenStore([FlutterSecureStorage? s])
      : _s = s ?? const FlutterSecureStorage();

  @override
  Future<String?> read() => _s.read(key: _key);
  @override
  Future<void> write(String token) => _s.write(key: _key, value: token);
  @override
  Future<void> delete() => _s.delete(key: _key);
}

/// An in-memory token store, for tests.
class MemoryTokenStore implements TokenStore {
  String? _t;
  MemoryTokenStore([this._t]);
  @override
  Future<String?> read() async => _t;
  @override
  Future<void> write(String token) async => _t = token;
  @override
  Future<void> delete() async => _t = null;
}

/// How the app builds a client. Injectable so tests can return a fake.
typedef ClientFactory = LymnalClient Function(String baseUrl, {String? token});

LymnalClient _defaultFactory(String baseUrl, {String? token}) =>
    LymnalClient(baseUrl: baseUrl, token: token);

/// The known machine on the tailnet (README · Machines). Discovery seeds from
/// here plus any server this device was last paired with.
const String kKnownServer = '100.127.82.110:7749';

enum LinkStatus { connecting, ok, unreachable, noTailnet, notApproved, firstRun }

class SessionController extends ChangeNotifier {
  final SharedPreferences _prefs;
  final TokenStore _tokens;
  final ClientFactory _factory;

  SessionController(this._prefs, this._tokens, {ClientFactory? factory})
      : _factory = factory ?? _defaultFactory;

  String? _token;
  String? _serverAddress; // host:port
  String? _serverName;
  LinkStatus _status = LinkStatus.connecting;
  LymnalClient? _client;
  Health? _health;

  LinkStatus get status => _status;
  String? get serverName => _serverName;
  String? get serverAddress => _serverAddress;
  Health? get health => _health;
  LymnalClient? get client => _client;
  bool get isFirstRun => _token == null;

  String _baseUrl(String address) => 'http://$address';

  /// Load the saved pairing and confirm the server answers. Call once at start.
  Future<void> boot() async {
    _token = await _tokens.read();
    _serverAddress = _prefs.getString('serverAddress');
    _serverName = _prefs.getString('serverName');

    if (_token == null || _serverAddress == null) {
      _setStatus(LinkStatus.firstRun);
      return;
    }
    _client = _factory(_baseUrl(_serverAddress!), token: _token);
    await refresh();
  }

  /// Re-check the server. Keeps the folder you were in on failure; the app
  /// retries while unreachable.
  Future<void> refresh() async {
    final c = _client;
    if (c == null) {
      _setStatus(LinkStatus.firstRun);
      return;
    }
    try {
      _health = await c.health();
      _setStatus(LinkStatus.ok);
    } on ConnectionError catch (e) {
      _setStatus(_statusFor(e.fault));
    } on LymnalError {
      // A coded error from health is unexpected; treat as reachable-but-odd.
      _setStatus(LinkStatus.ok);
    }
  }

  LinkStatus _statusFor(ConnectionFault f) => switch (f) {
        ConnectionFault.unreachable => LinkStatus.unreachable,
        ConnectionFault.noTailnet => LinkStatus.noTailnet,
        ConnectionFault.notApproved => LinkStatus.notApproved,
      };

  /// Try `health` on each candidate address, returning the servers that
  /// answer. Seeds from the last-paired server and the known machine.
  Future<List<DiscoveredServer>> discover({List<String> extra = const []}) async {
    final candidates = <String>{
      if (_serverAddress != null) _serverAddress!,
      kKnownServer,
      ...extra,
    };
    final found = <DiscoveredServer>[];
    for (final addr in candidates) {
      try {
        final probe = _factory(_baseUrl(addr));
        final h = await probe.health();
        found.add(DiscoveredServer(name: h.trove == '' ? addr : _nameFor(addr, h), address: addr, health: h));
      } on ConnectionError {
        // Not answering — skip.
      } on LymnalError {
        // Answered oddly, but it's a server — include it under its address.
        continue;
      }
    }
    return found;
  }

  String _nameFor(String addr, Health h) {
    // health has no device name field; fall back to the address host.
    return addr.split(':').first;
  }

  /// Request access to a server: call pair (which blocks until a person
  /// approves), then keep the token in the keyring and open on the trove.
  /// Rethrows [LymnalError] (denied / timed out / not open) for the UI to show.
  Future<void> requestAccess(
    String address, {
    required String deviceName,
    String clientName = 'elyxr/1.0.0',
  }) async {
    final c = _factory(_baseUrl(address));
    final result = await c.pair(deviceName, clientName);
    _token = result.token;
    _serverAddress = address;
    _serverName = address.split(':').first;
    await _tokens.write(result.token);
    await _prefs.setString('serverAddress', address);
    await _prefs.setString('serverName', _serverName!);
    _client = _factory(_baseUrl(address), token: _token);
    await refresh();
  }

  /// Forget this server: delete the token, drop the pairing, and return to
  /// first run. Changes nothing on the server (§10). The cache and elyxr-trove
  /// are handled by the caller, which owns those subsystems.
  Future<void> forget() async {
    await _tokens.delete();
    await _prefs.remove('serverAddress');
    await _prefs.remove('serverName');
    _token = null;
    _serverAddress = null;
    _serverName = null;
    _client = null;
    _health = null;
    _setStatus(LinkStatus.firstRun);
  }

  void _setStatus(LinkStatus s) {
    _status = s;
    notifyListeners();
  }
}
