// Runs `lymnal update` from inside the app, then closes and reopens the app on
// its own once the rebuild is done — no button, no confirmation. Updates are
// bidirectional: pressing update on any owner device updates the whole fleet.
// On the server that means rebuild-then-announce; on a client it asks the server
// to update everyone (the server broadcasts and updates itself), and this
// device's own agent applies the update in the background and restarts the app.
//
// Android is the exception: it can't rebuild or silently self-replace, so it
// updates the Android-legal way — ask the release which APK is published, and if
// that build is newer than this one, download it and hand it to the system
// package installer, which asks the user to Install (one tap). Every build is
// signed with the same committed key, so it installs in place over the old one.
// It asks the server to update the fleet first, because a phone cannot run
// `lymnal update` the way a desktop does.
//
// The rebuild replaces the app's own files, so it can't happen in place — the
// running app keeps its old copy while the new one lands beside it, and the
// relaunch is what steps onto the new build. The relaunch is automatic and
// silent, with one exception: if a file is mid-upload, it waits for that upload
// to finish first (the server keeps upload state in memory, so restarting
// mid-upload would lose it), then relaunches the instant it's done.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../util/build_info.dart';
import '../util/platform_caps.dart';
import 'session.dart';

enum UpdateStage { idle, updating, waitingForUpload, failed, upToDate }

class UpdateController extends ChangeNotifier {
  final SessionController session;

  UpdateController(this.session) {
    session.addListener(_onSession);
  }

  UpdateStage stage = UpdateStage.idle;
  String? error;
  int _actingOnBuild = 0;

  /// The last fleet announcement this controller has acted on. The server
  /// broadcasts an update event, BrowseController turns it into
  /// [SessionController.signalPeerUpdate], and this is what finally listens —
  /// nothing did before, so an announced update reached the app and stopped
  /// there, which is why the fleet never carried a client along with it.
  int _seenPeerSignal = 0;

  void _onSession() {
    final sig = session.peerUpdateSignal;
    if (sig == _seenPeerSignal) return;
    _seenPeerSignal = sig;
    final serverBuild = session.health?.build ?? 0;
    if (serverBuild > 0) noticeBehind(serverBuild);
  }
  // Guards the "updating" spinner on the client fleet-request path, where the
  // background agent (not this process) applies the update and restarts the app.
  Timer? _fleetTimeout;

  bool get busy => stage == UpdateStage.updating || stage == UpdateStage.waitingForUpload;

  @override
  void dispose() {
    session.removeListener(_onSession);
    super.dispose();
  }

  String _bin(String name) {
    final home = Platform.environment['HOME'];
    for (final path in [
      if (home != null) '$home/.local/bin/$name',
      '/usr/local/bin/$name',
    ]) {
      if (File(path).existsSync()) return path;
    }
    return name;
  }

  /// Called with the server's build when this client learns it's behind. Starts
  /// once per newer build; ignores repeat news while one is already running.
  void noticeBehind(int serverBuild) {
    if (busy) return;
    if (serverBuild <= _actingOnBuild) return;
    _actingOnBuild = serverBuild;
    _run();
  }

  /// Trigger the update by hand (the server's "update now", or the client acting
  /// on the server's live announcement).
  void updateNow() {
    if (busy) return;
    _run();
  }

  /// The release the Android APK is published to. The updater asks which assets
  /// are on it rather than fetching a fixed filename, because the asset's NAME
  /// carries the build number — so it learns which build is published before
  /// spending 125 MB, and can say "already current" instead of downloading blind.
  static const _androidReleaseApi =
      'https://api.github.com/repos/ryanj97g/elyxr/releases/tags/android-latest';

  /// The newest `elyxr-<build>.apk` on a release. Unnumbered assets are ignored:
  /// a name without a build in it can't be checked against what's installed.
  @visibleForTesting
  static ({String url, int build})? pickApk(List<dynamic> assets) {
    final re = RegExp(r'^elyxr-(\d+)\.apk$');
    ({String url, int build})? best;
    for (final a in assets) {
      if (a is! Map) continue;
      final m = re.firstMatch((a['name'] as String?) ?? '');
      final url = a['browser_download_url'] as String?;
      if (m == null || url == null) continue;
      final b = int.tryParse(m.group(1)!);
      if (b == null) continue;
      if (best == null || b > best.build) best = (url: url, build: b);
    }
    return best;
  }

  /// Ask the server to update everyone. Failing this must not stop this device
  /// updating itself, so it's reported and stepped over rather than thrown.
  Future<String?> _askFleetToUpdate() async {
    final client = session.client;
    if (client == null) return 'not connected to a server';
    try {
      await client.updateFleet();
      return null;
    } catch (e) {
      return '$e';
    }
  }

  Future<void> _run() async {
    // Android can't rebuild itself and can't silently self-replace, but it can
    // do it the legal way: download the new APK and hand it to the system
    // package installer, which prompts the user to Install (one tap). Every
    // build is signed with the same committed key, so it installs over the top.
    if (Caps.isAndroid) {
      stage = UpdateStage.updating;
      error = null;
      notifyListeners();
      // The fleet first, so everyone else starts while this phone downloads.
      // Desktop gets this from `lymnal update`; a phone can't run that, so this
      // call is the only way pressing update here moves anything but this device.
      final fleetProblem = await _askFleetToUpdate();
      final client = http.Client();
      try {
        final rel = await client
            .get(Uri.parse(_androidReleaseApi),
                headers: {'Accept': 'application/vnd.github+json'})
            .timeout(const Duration(seconds: 20));
        if (rel.statusCode != 200) {
          throw 'GitHub answered ${rel.statusCode} when asked which APK is published';
        }
        final assets =
            (jsonDecode(rel.body) as Map<String, dynamic>)['assets'] as List? ?? [];
        final pick = pickApk(assets);
        if (pick == null) {
          throw 'the android-latest release has no elyxr-<build>.apk on it';
        }
        // Knowing the build before downloading is the whole point of the lookup.
        if (appBuild > 0 && pick.build <= appBuild) {
          stage = UpdateStage.upToDate;
          error = 'Build ${pick.build} is published; this device is on $appBuild.';
          notifyListeners();
          return;
        }

        final dir = await getTemporaryDirectory();
        final f = File('${dir.path}/elyxr-${pick.build}.apk');
        final resp = await client.send(http.Request('GET', Uri.parse(pick.url)));
        if (resp.statusCode != 200) {
          throw 'the download answered ${resp.statusCode}';
        }
        final sink = f.openWrite();
        await resp.stream.pipe(sink);
        await sink.close();
        // A truncated download hands the installer a broken file, which it
        // reports as a corrupt package rather than as a failed download.
        final got = await f.length();
        final want = resp.contentLength;
        if (want != null && got != want) {
          throw 'the download stopped early ($got of $want bytes)';
        }

        final res = await OpenFilex.open(
          f.path,
          type: 'application/vnd.android.package-archive',
        );
        if (res.type == ResultType.done) {
          // The system installer has it now; nothing left for us to drive.
          stage = UpdateStage.idle;
        } else {
          stage = UpdateStage.failed;
          error = 'Downloaded build ${pick.build}, but the installer wouldn\'t '
              'open it: ${res.message}. Allow "install unknown apps" for elyxr.';
        }
        notifyListeners();
      } catch (e) {
        stage = UpdateStage.failed;
        error = 'Update failed: $e'
            '${fleetProblem != null ? ' (the fleet wasn\'t told either: $fleetProblem)' : ''}';
        notifyListeners();
      } finally {
        client.close();
      }
      return;
    }
    // Any other no-exec platform (e.g. iOS): there's nothing to fetch.
    if (!Caps.canExec) {
      stage = UpdateStage.failed;
      error = 'Update elyxr from the app store (or install the latest APK).';
      notifyListeners();
      return;
    }
    stage = UpdateStage.updating;
    error = null;
    notifyListeners();
    try {
      final proc = await Process.start(_bin('lymnal'), ['update']);
      proc.stdout.listen((_) {});
      proc.stderr.listen((_) {});
      final code = await proc.exitCode;
      if (code == 0) {
        // The update is launched. It runs detached (its own systemd scope),
        // rebuilds, and restarts this app when the new build is ready — so we
        // stay on "updating" and let that restart happen. This is the exact same
        // path the tray's "Update now" and `lymnal update` take.
        _fleetTimeout?.cancel();
        _fleetTimeout = Timer(const Duration(minutes: 10), () {
          if (stage == UpdateStage.updating) {
            stage = UpdateStage.idle;
            notifyListeners();
          }
        });
      } else {
        stage = UpdateStage.failed;
        error = 'The update didn\'t start (exit $code).';
        notifyListeners();
      }
    } catch (e) {
      stage = UpdateStage.failed;
      error = 'Could not start the update: $e';
      notifyListeners();
    }
  }

  /// Retry after a failed update.
  void retry() {
    if (busy) return;
    _run();
  }
}
