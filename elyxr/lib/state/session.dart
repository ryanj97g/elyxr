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
import '../util/lymnal_host.dart';
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

  // Whether boot() has finished. Until it has we haven't read the saved token yet,
  // so "no token" doesn't mean "never paired" — it means "don't know". Without
  // this the app would show the first-run screen for a moment on every launch.
  bool _booted = false;
  bool get booted => _booted;

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
  /// Never paired. False until [booted], because before that we simply haven't
  /// read the token yet and guessing "first run" would flash that screen at
  /// someone who has been paired for months.
  bool get isFirstRun => _booted && _token == null;
  /// The bearer token used to authenticate requests (never shown on screen).
  String? get bearerToken => _token;

  String _baseUrl(String address) => 'http://$address';

  /// A paired client on desktop talks to its *own* lymnal, which proxies to the
  /// trove with lymbo in front. Discovery and pairing still use the remote
  /// address, since that's how a device is found and approved.
  static const _localProxy = 'http://127.0.0.1:7749';

  /// Where the paired client points: its own local lymnal on loopback, which
  /// owns lymbo and fronts the trove. True everywhere the app runs its own
  /// lymnal — desktop (an OS service) and Android (a foreground service).
  /// Discovery and pairing still use the remote address, since that's how a
  /// device is found and approved. (The false branch is a defensive fallback
  /// for any platform without a local lymnal.)
  String get _clientBase =>
      Caps.hasLocalLymnal ? _localProxy : _baseUrl(_serverAddress!);

  /// Load the saved pairing and confirm the server answers. Call once at start.
  /// Load the saved pairing and confirm the server answers.
  ///
  /// Deliberately NOT awaited before the first frame — see main(). This talks to
  /// the network, and a machine that can't reach its server must still get a
  /// window. Every outcome here is a LinkStatus the UI already draws.
  Future<void> boot() async {
    try {
      await _boot();
    } finally {
      _booted = true;
      notifyListeners();
    }
  }

  Future<void> _boot() async {
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
    if (Caps.isAndroid) {
      // Bring the on-device lymnal up first, then wait for its loopback proxy to
      // start answering — right after launch it needs a moment to bind.
      await _syncLink();
      await _connectWithRetry();
    } else {
      await refresh();
      await _syncLink();
    }
    _startPolling();
  }

  /// Retry the first health check while a just-started local lymnal binds its
  /// loopback port. Falls through to whatever status the last attempt set, so
  /// polling still recovers if it isn't up within the window.
  Future<void> _connectWithRetry() async {
    for (var i = 0; i < 12; i++) {
      await refresh();
      if (_status == LinkStatus.ok) return;
      await Future.delayed(const Duration(milliseconds: 700));
    }
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
    if (Caps.isAndroid) {
      await _syncLinkAndroid();
      return;
    }
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

  /// Android has no $HOME and can't shell out, so link.json goes into the app's
  /// private data dir (where the foreground service points HOME/LYMNAL_CONFIG),
  /// and the service — not systemd — runs lymnal. The service reads link.json
  /// only at start, so it's stopped and restarted to pick up changes. Unlike
  /// desktop we always (re)start when paired: the OS may have killed the service.
  Future<void> _syncLinkAndroid() async {
    final dataDir = await LymnalHost.dataDir();
    if (dataDir == null) return;
    final f = File('$dataDir/lymnal/link.json');
    try {
      if (_token == null || _serverAddress == null) {
        if (await f.exists()) await f.delete();
        await LymnalHost.stop(); // unpaired — stop the proxy
        return;
      }
      final content = jsonEncode({
        'server': _serverAddress,
        'token': _token,
        'name': _serverName ?? _serverAddress,
      });
      await f.parent.create(recursive: true);
      await f.writeAsString(content);
      await LymnalHost.stop();
      await LymnalHost.start();
    } catch (_) {}
  }

  /// Put the local lymnal into the role this device is in right now, and say
  /// whether that changed anything.
  ///
  /// lymnal picks its role once, at startup: link.json present means it runs as
  /// a client proxy, and the proxy serves no admin surface at all. So server
  /// mode has to take link.json away first, or the Server controls have nothing
  /// to talk to and every one of them fails against an address nothing is
  /// listening on. Client mode puts link.json back from the saved pairing.
  ///
  /// The saved pairing (token and server address) is left alone either way, so
  /// switching to server mode and back does not unpair the device.
  Future<bool> applyRole({required bool server}) async {
    if (!server) {
      await _syncLink();
      return true;
    }
    if (Caps.isAndroid) {
      final dataDir = await LymnalHost.dataDir();
      if (dataDir == null) return false;
      final f = File('$dataDir/lymnal/link.json');
      if (!await f.exists()) return false;
      await f.delete();
      await LymnalHost.stop();
      await LymnalHost.start();
      return true;
    }
    final home = _homeDir();
    if (home == null) return false;
    try {
      final f = File('$home/.config/lymnal/link.json');
      if (!await f.exists()) return false; // already a server — leave it alone
      await f.delete();
      // address and admin.token are published by lymnal at startup, and the
      // copies on disk are from its last run as a server. Clear them so the
      // restarted service is what republishes them, rather than server mode
      // reading back values that no longer describe anything running.
      for (final name in const ['address', 'admin.token']) {
        final stale = File('$home/.local/share/lymnal/$name');
        if (await stale.exists()) await stale.delete();
      }
      await _restartLymnal(running: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Set by tests to a temporary directory. While it is set this controller
  /// keeps to itself: config is read and written under that directory instead of
  /// the real home, and the machine's lymnal service is left alone.
  ///
  /// boot() calls _syncLink(), which writes the REAL ~/.config/lymnal/link.json
  /// and then restarts lymnal. Unsandboxed, running the suite on a paired device
  /// replaced its pairing with whatever fake server a test had mocked and bounced
  /// the service — the device silently unpaired, with nothing on screen to say so.
  @visibleForTesting
  static String? sandboxHome;

  /// The user's home directory, matching lymnal's own resolution so link.json
  /// lands where lymnal looks for it: `%USERPROFILE%` first on Windows, `$HOME`
  /// first elsewhere.
  String? _homeDir() {
    if (sandboxHome != null) return sandboxHome;
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
    // The other half: bouncing lymnal is a real side effect on the developer's
    // own device, not something a unit test may do.
    if (sandboxHome != null) return;
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
    // Write link.json first so lymnal (re)starts as this device's local proxy,
    // then refresh. On Android the just-started service needs a moment to bind,
    // so retry until the loopback proxy answers.
    await _syncLink();
    if (Caps.isAndroid) {
      await _connectWithRetry();
    } else {
      await refresh();
    }
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
      // Local browsing overwrote the displayed name with the folder's; the saved
      // pairing still knows what the server is called.
      _serverName = _prefs.getString('serverName') ?? _serverAddress;
      notifyListeners();
      refresh();
    }
  }
}
