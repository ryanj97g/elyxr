// Who this device is paired with, and whether the server can be reached.
//
// The token lives in the system keyring (never in prefs, never on screen). The
// server's address and name are ordinary prefs. First run is simply "no token
// yet" (§08); forgetting a server returns here (§10).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_error.dart';
import '../api/local_trove_client.dart';
import '../api/lymnal_client.dart';
import '../api/models.dart';
import '../util/platform_caps.dart';

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
  /// The bearer token, for handing to the trove mount (never shown on screen).
  String? get bearerToken => _token;

  String _baseUrl(String address) => 'http://$address';

  /// A paired client on desktop talks to its *own* lymnal, which proxies to the
  /// trove with lymbo in front. Discovery and pairing still use the remote
  /// address, since that's how a device is found and approved.
  static const _localProxy = 'http://127.0.0.1:7749';

  /// Where the paired client points. Desktop has a local lymnal on loopback (it
  /// owns lymbo and fronts the trove). A phone has no local proxy, so it talks
  /// straight to the remote lymnal over the tailnet, carrying the bearer token
  /// itself — the same address pairing/discovery already use. (No local lymbo on
  /// mobile yet; that's the on-device lymnal, still to come.)
  String get _clientBase =>
      Caps.hasLocalLymnal ? _localProxy : _baseUrl(_serverAddress!);

  /// Load the saved pairing and confirm the server answers. Call once at start.
  Future<void> boot() async {
    await _importPendingBind();
    _token = await _tokens.read();
    _serverAddress = _prefs.getString('serverAddress');
    _serverName = _prefs.getString('serverName');

    if (_token == null || _serverAddress == null) {
      await _syncLink(); // no pairing: make sure lymnal isn't left as an agent
      _setStatus(LinkStatus.firstRun);
      return;
    }
    _client = _factory(_clientBase, token: _token);
    await refresh();
    await _syncLink();
    _startPolling();
  }

  /// Bumped when the server announces (over the live stream) that an update is
  /// starting there, so a client can update in step. A counter rather than a
  /// flag so each announcement is a distinct event the UI can react to.
  int _peerUpdate = 0;
  int get peerUpdateSignal => _peerUpdate;
  void signalPeerUpdate() {
    _peerUpdate++;
    notifyListeners();
  }

  /// Pairing done from the terminal (`lymnal bind <address>`) leaves the new
  /// connection in a small file for the app to adopt. Import it once: move the
  /// token into the keyring, remember the server, and delete the file.
  Future<void> _importPendingBind() async {
    final home = _homeDir();
    if (home == null) return;
    final f = File('$home/.config/lymnal/pending-bind.json');
    try {
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final token = j['token'] as String?;
      final address = j['address'] as String?;
      if (token != null && token.isNotEmpty && address != null && address.isNotEmpty) {
        await _tokens.write(token);
        await _prefs.setString('serverAddress', address);
        await _prefs.setString('serverName', (j['name'] as String?) ?? address);
      }
      await f.delete();
    } catch (_) {
      // A malformed hand-off file must never block startup.
    }
  }

  /// Keep ~/.config/lymnal/link.json in step with the current pairing. The
  /// lymnal background service reads it to know this device is a client and
  /// which server to stay connected to — that's what keeps the device updated
  /// with the app closed. When the contents change, nudge lymnal to re-read.
  Future<void> _syncLink() async {
    final home = _homeDir();
    if (home == null) return;
    final f = File('$home/.config/lymnal/link.json');
    try {
      if (_token == null || _serverAddress == null) {
        if (await f.exists()) {
          await f.delete();
          await _restartLymnal(running: false); // unpaired — stop the proxy
        }
        return;
      }
      final content = jsonEncode({
        'server': _serverAddress,
        'token': _token,
        'name': _serverName ?? _serverAddress,
      });
      final existing = await f.exists() ? await f.readAsString() : null;
      if (existing == content) return; // already current — don't restart lymnal
      await f.parent.create(recursive: true);
      await f.writeAsString(content);
      await _restartLymnal(running: true);
    } catch (_) {}
  }

  /// The user's home directory, matching lymnal's own resolution so link.json
  /// lands where lymnal looks for it: `%USERPROFILE%` first on Windows, `$HOME`
  /// first elsewhere.
  String? _homeDir() {
    final env = Platform.environment;
    final order = Platform.isWindows
        ? const ['USERPROFILE', 'HOME']
        : const ['HOME', 'USERPROFILE'];
    for (final v in order) {
      final val = env[v];
      if (val != null && val.isNotEmpty) return val;
    }
    return null;
  }

  /// Restart the lymnal service so it re-reads link.json — the one place the app
  /// touches the service's lifecycle, done the platform's way. On Linux that's
  /// systemd; on Windows there's no service manager reachable from here, so stop
  /// the process and relaunch it hidden from where the app is installed. When
  /// [running] is false (the device was unpaired) it's only stopped.
  Future<void> _restartLymnal({required bool running}) async {
    if (Platform.isLinux) {
      await Process.run('systemctl', ['--user', 'restart', 'lymnal.service']);
      return;
    }
    if (Platform.isWindows) {
      await Process.run('taskkill', ['/IM', 'lymnal.exe', '/F']);
      if (!running) return;
      final dir = File(Platform.resolvedExecutable).parent.path;
      final vbs = File('$dir\\lymnal-launch.vbs');
      if (await vbs.exists()) {
        // The installed hidden launcher: no console window.
        await Process.start('wscript', [vbs.path],
            mode: ProcessStartMode.detached);
      } else {
        // Running from the raw zip (no installer): launch lymnal directly.
        await Process.start('$dir\\lymnal.exe', const [],
            mode: ProcessStartMode.detached);
      }
    }
  }

  /// Re-check the server every so often while paired, so a change on the server
  /// — including it moving to a newer build — is noticed live rather than only
  /// at app start. Cheap: one small health call.
  Timer? _poll;
  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 45), (_) {
      if (_client != null) refresh();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
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
  /// answer. Seeds from the last-paired server (if any) and whatever address
  /// the person typed — nothing is hardcoded, so a first run means entering a
  /// server address by hand.
  Future<List<DiscoveredServer>> discover({List<String> extra = const []}) async {
    final candidates = <String>{
      if (_serverAddress != null) _serverAddress!,
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
    _client = _factory(_clientBase, token: _token);
    // Write link.json first so lymnal restarts as this device's local proxy,
    // then refresh — which retries until the proxy is answering.
    await _syncLink();
    await refresh();
  }

  /// Forget this server: delete the token, drop the pairing, and return to
  /// first run. Changes nothing on the server (§10). The cache and trove
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
    await _syncLink(); // removes link.json and returns lymnal to serving
    _setStatus(LinkStatus.firstRun);
  }

  void _setStatus(LinkStatus s) {
    _status = s;
    notifyListeners();
  }

  /// Server mode: browse the trove straight off local disk. No token — the files
  /// are on this machine. The browser uses [client] the same as always; it just
  /// happens to be a local-filesystem-backed one here.
  void useLocalTrove(String troveRoot) {
    _client = LocalTroveClient(troveRoot);
    _serverName = troveRoot.split('/').last;
    _status = LinkStatus.ok;
    notifyListeners();
  }

  /// Return to talking to a remote server over the network (after leaving server
  /// mode), rebuilding the client from the saved pairing.
  void useRemote() {
    if (_serverAddress != null) {
      _client = _factory(_clientBase, token: _token);
      refresh();
    }
  }
}
