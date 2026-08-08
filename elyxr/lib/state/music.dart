// The music player, on audioplayers (GStreamer on Linux — the system's own
// codecs). Plays whatever is in assets/music/ plus any audio file streamed from
// the trove. mp3/ogg/wav/flac play directly; tracker modules (.xm/.mod/.s3m/.it)
// are rendered to WAV on load (openmpt123) first. Playback never depends on the
// visualizer — that's a separate concern entirely now.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:path_provider/path_provider.dart';

import '../api/lymnal_client.dart';

/// Audio extensions the player accepts — common formats GStreamer decodes
/// directly, plus tracker modules (.xm/.mod/.s3m/.it) which are rendered to PCM
/// on load (see _renderModule) so they play too.
const kAudioExts = {
  'ogg', 'mp3', 'wav', 'flac', 'm4a', 'aac', 'opus',
  'xm', 'mod', 's3m', 'it',
};

bool isAudioName(String name) =>
    kAudioExts.contains(name.split('.').last.toLowerCase());

/// Loop nothing, the whole list, or the one track.
enum MusicRepeat { off, all, one }

class MusicController extends ChangeNotifier {
  final _rnd = math.Random();
  final AudioPlayer _player = AudioPlayer();

  List<String> _tracks = []; // asset keys under assets/music/
  int _index = 0;
  bool _playing = false;
  bool _shuffle = false;
  MusicRepeat _repeat = MusicRepeat.off;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  bool _hasSource = false;
  // Set when playing a one-off trove stream (not the asset playlist); overrides
  // the shown title and hides the playlist index.
  String? _override;

  MusicController() {
    _player.onPositionChanged.listen((d) {
      _pos = d;
      notifyListeners();
    });
    _player.onDurationChanged.listen((d) {
      _dur = d;
      notifyListeners();
    });
    _player.onPlayerStateChanged.listen((s) {
      _playing = s == PlayerState.playing;
      notifyListeners();
    });
    _player.onPlayerComplete.listen((_) => _onComplete());
    _load();
  }

  List<String> get tracks => _tracks;
  bool get hasTracks => _tracks.isNotEmpty;
  int get index => _index;
  int get count => _tracks.length;
  bool get playing => _playing;
  bool get shuffle => _shuffle;
  MusicRepeat get repeat => _repeat;
  Duration get position => _pos;
  Duration get duration => _dur;
  String get title =>
      _override ?? (hasTracks ? _pretty(_tracks[_index]) : 'no tracks');
  String titleAt(int i) => _pretty(_tracks[i]);
  bool get isStream => _override != null;
  bool get active => _hasSource && (_playing || _pos > Duration.zero);

  Future<void> _load() async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      _tracks = manifest
          .listAssets()
          .where((a) => a.startsWith('assets/music/') && isAudioName(a))
          .toList()
        ..sort();
    } catch (_) {
      _tracks = [];
    }
    notifyListeners();
  }

  String _pretty(String asset) {
    var n = asset.split('/').last;
    final dot = n.lastIndexOf('.');
    if (dot > 0) n = n.substring(0, dot);
    return n.replaceAll(RegExp(r'[_-]+'), ' ').trim();
  }

  /// Start the built-in easter-egg soundtrack from the top — what Nostalgia Mode
  /// triggers when it switches on. No-op if the baked-in playlist is empty.
  Future<void> startBuiltIn() async {
    if (_tracks.isEmpty) return;
    await playIndex(0);
  }

  static const _moduleExts = {'xm', 'mod', 's3m', 'it'};
  bool _isModule(String ext) => _moduleExts.contains(ext.toLowerCase());

  /// Build a playable source for a bundled asset. A normal format plays straight
  /// from assets; a tracker module is extracted and rendered to WAV first.
  Future<Source> _assetSource(String assetKey) async {
    final ext = assetKey.split('.').last.toLowerCase();
    if (!_isModule(ext)) {
      // AssetSource prepends 'assets/'; our keys already start with it.
      return AssetSource(assetKey.replaceFirst('assets/', ''));
    }
    final data = await rootBundle.load(assetKey);
    final dir = await getTemporaryDirectory();
    final src =
        File('${dir.path}/elyxr_asset_${assetKey.hashCode & 0x7fffffff}.$ext');
    await src.writeAsBytes(data.buffer.asUint8List(), flush: true);
    final wav = await _renderModule(src.path, ext);
    return DeviceFileSource(wav);
  }

  /// Render a tracker module to a temp WAV (openmpt123, ffmpeg as a fallback) so
  /// it can be played like any other file. Cached by input path; returns the
  /// original path if no renderer is available.
  Future<String> _renderModule(String inPath, String ext) async {
    final dir = await getTemporaryDirectory();
    final out = '${dir.path}/elyxr_mod_${inPath.hashCode & 0x7fffffff}.wav';
    if (File(out).existsSync()) return out;
    final attempts = <List<String>>[
      ['openmpt123', '--quiet', '--force', '--render', '-o', out, inPath],
      ['ffmpeg', '-y', '-loglevel', 'error', '-i', inPath, out],
    ];
    for (final a in attempts) {
      try {
        final r = await Process.run(a.first, a.sublist(1));
        if (r.exitCode == 0 && File(out).existsSync()) return out;
      } catch (_) {
        // renderer not installed — try the next
      }
    }
    return inPath;
  }

  Future<void> playIndex(int i) async {
    if (_tracks.isEmpty) return;
    _index = i % _tracks.length;
    if (_index < 0) _index += _tracks.length;
    _override = null;
    _pos = Duration.zero;
    try {
      final src = await _assetSource(_tracks[_index]);
      await _player.stop();
      await _player.play(src);
      _hasSource = true;
      _playing = true;
    } catch (_) {
      _playing = false;
    }
    notifyListeners();
  }

  /// Stream and play one audio file from the trove (long-press on a client file
  /// row). Downloads it through the local proxy to a temp file, then plays it.
  Future<void> playTroveFile(
      LymnalClient client, String path, String name) async {
    try {
      final bytes = await client.downloadBytes(path);
      final dir = await getTemporaryDirectory();
      final dot = path.lastIndexOf('.');
      final ext = dot >= 0 ? path.substring(dot + 1).toLowerCase() : '';
      final f = File('${dir.path}/elyxr_stream.$ext');
      await f.writeAsBytes(bytes, flush: true);
      final playable = _isModule(ext) ? await _renderModule(f.path, ext) : f.path;
      await _player.stop();
      await _player.play(DeviceFileSource(playable));
      _override = _pretty(name);
      _hasSource = true;
      _pos = Duration.zero;
      _playing = true;
    } catch (_) {
      _playing = false;
    }
    notifyListeners();
  }

  Future<void> toggle() async {
    if (!_hasSource) {
      if (_tracks.isNotEmpty) return playIndex(_index);
      return;
    }
    try {
      if (_playing) {
        await _player.pause();
        _playing = false;
      } else {
        await _player.resume();
        _playing = true;
      }
    } catch (_) {}
    notifyListeners();
  }

  void toggleShuffle() {
    _shuffle = !_shuffle;
    notifyListeners();
  }

  void cycleRepeat() {
    _repeat = MusicRepeat.values[(_repeat.index + 1) % MusicRepeat.values.length];
    notifyListeners();
  }

  int _pickNext() {
    if (_shuffle && _tracks.length > 1) {
      int r;
      do {
        r = _rnd.nextInt(_tracks.length);
      } while (r == _index);
      return r;
    }
    return (_index + 1) % _tracks.length;
  }

  Future<void> next() =>
      _tracks.isEmpty ? Future<void>.value() : playIndex(_pickNext());

  Future<void> prev() {
    if (_tracks.isEmpty) return Future<void>.value();
    if (_pos.inSeconds > 3) return seek(Duration.zero);
    return playIndex(_shuffle && _tracks.length > 1 ? _pickNext() : _index - 1);
  }

  // A track ended on its own: honour repeat/shuffle.
  void _onComplete() {
    if (_repeat == MusicRepeat.one) {
      playIndex(_index);
    } else if (_shuffle || _repeat == MusicRepeat.all) {
      next();
    } else if (_index < _tracks.length - 1) {
      next();
    } else {
      _playing = false;
      _pos = Duration.zero;
      notifyListeners();
    }
  }

  Future<void> seek(Duration to) async {
    try {
      await _player.seek(to);
      _pos = to;
      notifyListeners();
    } catch (_) {}
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }
}
