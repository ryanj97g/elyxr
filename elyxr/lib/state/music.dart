// The Nostalgia Mode music player, on the SoLoud engine. A playlist of whatever
// is in assets/music/ (.ogg/.mp3/.wav), with play/pause, seek, skip, shuffle and
// repeat. Position is polled (SoLoud has no position stream); a track ending is
// detected by its voice handle going invalid. All playback is guarded so a
// missing file or absent audio device never affects the app.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:path_provider/path_provider.dart';

import '../api/lymnal_client.dart';

/// Audio extensions the player accepts — common formats SoLoud decodes directly,
/// plus tracker modules (.xm/.mod/.s3m/.it, demoscene/keygen fare) which are
/// rendered to PCM on load (see MusicController._renderModule) so they play too.
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

  List<String> _tracks = []; // asset keys under assets/music/
  int _index = 0;
  bool _playing = false;
  bool _shuffle = false;
  MusicRepeat _repeat = MusicRepeat.off;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;

  AudioSource? _source;
  SoundHandle? _handle;
  Timer? _poll;
  // Set when playing a one-off file streamed from the trove (not the asset
  // playlist); overrides the shown title and hides the playlist index.
  String? _override;

  MusicController() {
    _load();
  }

  SoLoud get _sl => SoLoud.instance;
  bool get _ready => _sl.isInitialized;

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
  bool get active => _source != null && (_playing || _pos > Duration.zero);

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

  Future<void> playIndex(int i) async {
    if (_tracks.isEmpty || !_ready) return;
    _index = i % _tracks.length;
    if (_index < 0) _index += _tracks.length;
    _override = null;
    _pos = Duration.zero;
    try {
      if (_handle != null) await _sl.stop(_handle!);
      _source = await _loadAssetPlayable(_tracks[_index]);
      _dur = _sl.getLength(_source!);
      _handle = _sl.play(_source!, volume: 0.9);
      _playing = true;
      _startPoll();
    } catch (_) {
      _playing = false;
    }
    notifyListeners();
  }

  /// Start the built-in easter-egg soundtrack from the top. This is what
  /// Nostalgia Mode triggers when it switches on. No-op if audio is down or the
  /// baked-in playlist is empty; if something is already playing it restarts the
  /// playlist from the first track.
  Future<void> startBuiltIn() async {
    if (!_ready || _tracks.isEmpty) return;
    await playIndex(0);
  }

  /// Stream and play one audio file from the trove (long-press on a client file
  /// row). Downloads it through the local proxy to a temp file, then plays it.
  Future<void> playTroveFile(
      LymnalClient client, String path, String name) async {
    if (!_ready) return;
    try {
      final bytes = await client.downloadBytes(path);
      final dir = await getTemporaryDirectory();
      final dot = path.lastIndexOf('.');
      final ext = dot >= 0 ? path.substring(dot + 1).toLowerCase() : '';
      final f = File('${dir.path}/elyxr_stream.$ext');
      await f.writeAsBytes(bytes, flush: true);
      if (_handle != null) await _sl.stop(_handle!);
      // A tracker module has to be rendered to PCM first (SoLoud can't decode
      // them); everything else SoLoud loads directly.
      final playable = _isModule(ext) ? await _renderModule(f.path, ext) : f.path;
      _source = await _sl.loadFile(playable);
      _dur = _sl.getLength(_source!);
      _override = _pretty(name);
      _pos = Duration.zero;
      _handle = _sl.play(_source!, volume: 0.9);
      _playing = true;
      _startPoll();
    } catch (_) {
      _playing = false;
    }
    notifyListeners();
  }

  // Tracker-module extensions SoLoud can't decode on its own — rendered to WAV
  // first (see _renderModule).
  static const _moduleExts = {'xm', 'mod', 's3m', 'it'};
  bool _isModule(String ext) => _moduleExts.contains(ext.toLowerCase());

  /// Load a bundled track. A normal format goes straight into SoLoud; a tracker
  /// module is extracted to disk and rendered to WAV first, because SoLoud has no
  /// module decoder.
  Future<AudioSource> _loadAssetPlayable(String assetKey) async {
    final ext = assetKey.split('.').last.toLowerCase();
    if (!_isModule(ext)) return _sl.loadAsset(assetKey);
    final data = await rootBundle.load(assetKey);
    final dir = await getTemporaryDirectory();
    final src = File('${dir.path}/elyxr_asset_${assetKey.hashCode & 0x7fffffff}.$ext');
    await src.writeAsBytes(data.buffer.asUint8List(), flush: true);
    final wav = await _renderModule(src.path, ext);
    return _sl.loadFile(wav);
  }

  /// Render a tracker module (.xm/.mod/.s3m/.it) to a temp WAV so SoLoud — which
  /// only decodes mp3/ogg/wav/flac — can play it, with the FFT visualiser still
  /// reacting since it's PCM by then. Prefers openmpt123 (a purpose-built module
  /// renderer, installed by elyxr.sh); falls back to ffmpeg if it's present.
  /// Cached by input path. If no renderer is available it returns the original
  /// path unchanged (SoLoud then simply won't load it — no worse than before).
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

  void _startPoll() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final h = _handle;
      if (h == null) return;
      if (!_sl.getIsValidVoiceHandle(h)) {
        _onComplete();
        return;
      }
      _pos = _sl.getPosition(h);
      if (_dur == Duration.zero && _source != null) _dur = _sl.getLength(_source!);
      notifyListeners();
    });
  }

  Future<void> toggle() async {
    if (_tracks.isEmpty || !_ready) return;
    if (_handle == null) return playIndex(_index);
    try {
      _playing = !_playing;
      _sl.setPause(_handle!, !_playing);
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

  // A track ended on its own (handle went invalid): honour repeat/shuffle.
  void _onComplete() {
    if (_repeat == MusicRepeat.one) {
      playIndex(_index);
    } else if (_shuffle || _repeat == MusicRepeat.all) {
      next();
    } else if (_index < _tracks.length - 1) {
      next();
    } else {
      _poll?.cancel();
      _handle = null;
      _playing = false;
      _pos = Duration.zero;
      notifyListeners();
    }
  }

  Future<void> seek(Duration to) async {
    if (_handle == null || !_ready) return;
    try {
      _sl.seek(_handle!, to);
      _pos = to;
      notifyListeners();
    } catch (_) {}
  }

  @override
  void dispose() {
    _poll?.cancel();
    final h = _handle;
    if (h != null && _ready) {
      try {
        _sl.stop(h);
      } catch (_) {}
    }
    super.dispose();
  }
}
