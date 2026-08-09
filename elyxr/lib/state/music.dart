// The music player, on audioplayers (GStreamer on Linux — the system's own
// codecs). Plays whatever is in assets/music/ plus any audio file streamed from
// the trove. mp3/ogg/wav/flac play directly; tracker modules (.xm/.mod/.s3m/.it)
// are rendered to WAV on load (openmpt123) first. Playback never depends on the
// visualizer — that's a separate concern entirely now.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

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
  // Nostalgia's easter-egg shuffle. Separate from the user-facing _shuffle
  // toggle: only startBuiltIn (Nostalgia Mode) ever turns this on. While it's on,
  // the soundtrack auto-advances to a random *different* track every time one
  // ends — the keygen "how many songs ARE there?" effect — without ever changing
  // the player's own default order.
  bool _eggShuffle = false;
  // Nostalgia was switched off; after a grace period the built-in soundtrack
  // stops (a quick toggle back on cancels it). See scheduleBuiltInStop.
  Timer? _nostalgiaStop;
  MusicRepeat _repeat = MusicRepeat.off;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  bool _hasSource = false;
  // Set when playing a one-off trove stream (not the asset playlist); overrides
  // the shown title and hides the playlist index.
  String? _override;

  // ---- real-time visualizer data ----
  // The spectrum bars are NOT captured from the speakers (that path always lags
  // by a capture buffer). Instead the *actual audio of the current track* is
  // analysed once into a spectrogram (see _startSpectro), and the bars are read
  // straight off the live play head. Zero capture race — it's the real FFT of
  // the real audio, shown at the exact playback instant, so it locks to the beat
  // and updates as fast as the screen refreshes. Row-major [frame * kVisBars].
  Float32List? _spectro;
  int _spectroFrames = 0;
  double _spectroFps = 60.0;
  int _spectroToken = 0; // bumps per track so a stale async build is discarded

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

  /// Number of spectrum bars the analysis produces (and the visualizer draws).
  static const int kVisBars = _kVisBars;

  /// The spectrum bars (0..1) for the current play position — the real FFT of
  /// the real audio at exactly this instant. Empty until the current track's
  /// spectrogram has been analysed (the visualizer just rests flat until then).
  List<double> visualizerBars() {
    final s = _spectro;
    final n = _spectroFrames;
    if (s == null || n == 0) return const <double>[];
    var f = (_pos.inMicroseconds * _spectroFps / 1000000.0).floor();
    if (f < 0) f = 0;
    if (f >= n) f = n - 1;
    final base = f * kVisBars;
    return List<double>.generate(kVisBars, (b) => s[base + b].toDouble());
  }

  /// Analyse the actual audio file into a spectrogram on a background isolate,
  /// then hold it for the visualizer to sample by play position. Never blocks or
  /// affects playback: if analysis fails (no ffmpeg, odd file), the bars simply
  /// stay flat. Each call invalidates any earlier build via the token.
  Future<void> _startSpectro(String path) async {
    final token = ++_spectroToken;
    _spectro = null;
    _spectroFrames = 0;
    try {
      final res = await compute(_analyzeSpectrogram, path);
      if (token != _spectroToken) return; // track changed mid-analysis
      _spectro = res.data;
      _spectroFrames = res.frames;
      _spectroFps = res.fps;
    } catch (_) {
      if (token == _spectroToken) {
        _spectro = null;
        _spectroFrames = 0;
      }
    }
  }

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

  /// Start the built-in easter-egg soundtrack — what Nostalgia Mode triggers when
  /// it switches on. Never starts at track 0 or plays in order: it begins on a
  /// random track and, from then on, every track that ends is followed by a
  /// random *different* one (see _eggShuffle / _onComplete). No-op if the
  /// baked-in playlist is empty.
  Future<void> startBuiltIn() async {
    if (_tracks.isEmpty) return;
    cancelBuiltInStop();
    _eggShuffle = true;
    await playIndex(_tracks.length == 1 ? 0 : _rnd.nextInt(_tracks.length));
  }

  /// Nostalgia Mode was switched off. After a 3-second grace period (so a quick
  /// toggle off/on doesn't cut the music), stop the built-in easter-egg
  /// soundtrack and return the player to rest — BUT only if what's playing is
  /// that soundtrack (an asset track). A trove file the user started streaming
  /// is theirs and keeps playing. Same behaviour in server and client mode, since
  /// it's the one shared player either way.
  void scheduleBuiltInStop() {
    _nostalgiaStop?.cancel();
    _nostalgiaStop = Timer(const Duration(seconds: 3), () {
      if (_playing && !isStream) stopPlayback();
    });
  }

  /// Cancel a pending built-in stop (Nostalgia was toggled back on in time).
  void cancelBuiltInStop() {
    _nostalgiaStop?.cancel();
    _nostalgiaStop = null;
  }

  /// Stop playback entirely and return the player to its resting state — from
  /// here it only plays again when the user picks a trove file (or Nostalgia
  /// restarts the soundtrack). Clears the easter-egg shuffle too.
  Future<void> stopPlayback() async {
    _nostalgiaStop?.cancel();
    _eggShuffle = false;
    try {
      await _player.stop();
    } catch (_) {}
    _playing = false;
    _hasSource = false;
    _override = null;
    _pos = Duration.zero;
    notifyListeners();
  }

  /// A random track index different from the one playing now (or 0 if there's
  /// only one). Used by the easter-egg shuffle; independent of _shuffle.
  int _pickRandom() {
    if (_tracks.length <= 1) return 0;
    int r;
    do {
      r = _rnd.nextInt(_tracks.length);
    } while (r == _index);
    return r;
  }

  static const _moduleExts = {'xm', 'mod', 's3m', 'it'};
  bool _isModule(String ext) => _moduleExts.contains(ext.toLowerCase());

  /// Build a playable source for a bundled asset, plus a local file path the
  /// visualizer can analyse. A normal format plays straight from assets but is
  /// also copied to a temp file so its spectrum can be computed; a tracker
  /// module is extracted and rendered to WAV, which serves both purposes.
  Future<(Source, String)> _assetSource(String assetKey) async {
    final ext = assetKey.split('.').last.toLowerCase();
    final data = await rootBundle.load(assetKey);
    final dir = await getTemporaryDirectory();
    final local =
        File('${dir.path}/elyxr_asset_${assetKey.hashCode & 0x7fffffff}.$ext');
    await local.writeAsBytes(data.buffer.asUint8List(), flush: true);
    if (_isModule(ext)) {
      final wav = await _renderModule(local.path, ext);
      return (DeviceFileSource(wav), wav);
    }
    // AssetSource prepends 'assets/'; our keys already start with it. The bars
    // read from the temp copy, not the bundle, so both stay in sync.
    return (AssetSource(assetKey.replaceFirst('assets/', '')), local.path);
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
      final (src, analysisPath) = await _assetSource(_tracks[_index]);
      await _player.stop();
      await _player.play(src);
      _hasSource = true;
      _playing = true;
      _startSpectro(analysisPath); // fire-and-forget; never blocks playback
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
      _startSpectro(playable); // real spectrum for the streamed file too
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

  // A track ended on its own: honour repeat/shuffle. Explicit repeat-one wins
  // (a user can still lock one track); otherwise Nostalgia's egg shuffle keeps
  // the soundtrack endlessly non-linear, never repeating back-to-back.
  void _onComplete() {
    if (_repeat == MusicRepeat.one) {
      playIndex(_index);
    } else if (_eggShuffle && _tracks.length > 1) {
      playIndex(_pickRandom());
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
    _spectroToken++; // orphan any in-flight analysis
    _nostalgiaStop?.cancel();
    _player.dispose();
    super.dispose();
  }
}

// ---- spectrogram analysis (runs on a background isolate) ----

const int _kVisBars = 28;

/// A precomputed spectrogram: [frames * _kVisBars] bar levels (0..1), row-major,
/// at [fps] frames per second. Sampled by play position for the visualizer.
class _SpectroResult {
  final Float32List data;
  final int frames;
  final double fps;
  const _SpectroResult(this.data, this.frames, this.fps);
}

/// Decode the actual audio at [path] to PCM (via ffmpeg) and turn it into a
/// spectrogram — a real FFT per video-frame-sized hop across the whole track.
/// Runs on a background isolate (see compute), so the heavy work never touches
/// the UI thread. On any failure it throws and the caller leaves the bars flat.
Future<_SpectroResult> _analyzeSpectrogram(String path) async {
  const int rate = 22050; // plenty for a bar visualizer, quick to process
  const double fps = 60.0; // one spectrum per screen frame
  const int win = 1024; // FFT window (power of two)
  final int hop = (rate / fps).round();

  // ffmpeg decodes anything GStreamer can play to raw mono s16le on stdout.
  final res = await Process.run(
    'ffmpeg',
    [
      '-v', 'error',
      '-i', path,
      '-f', 's16le',
      '-acodec', 'pcm_s16le',
      '-ac', '1',
      '-ar', '$rate',
      'pipe:1',
    ],
    stdoutEncoding: null, // raw bytes, not text
  );
  final raw = res.stdout as List<int>;
  final bytes = raw is Uint8List ? raw : Uint8List.fromList(raw);
  final nSamples = bytes.length ~/ 2;
  if (nSamples < win) throw StateError('too short to analyse');

  // s16le bytes -> normalized samples.
  final bd = ByteData.sublistView(bytes, 0, nSamples * 2);
  final samples = Float64List(nSamples);
  for (var i = 0; i < nSamples; i++) {
    samples[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
  }

  // Log-spaced band edges (shared across frames): ~85Hz .. ~11kHz.
  final half = win ~/ 2;
  const int loBin = 2;
  final int hiBin = (half - 1).clamp(loBin + 1, half);
  final edges = List<int>.generate(_kVisBars + 1, (b) {
    final v = (loBin * math.pow(hiBin / loBin, b / _kVisBars)).round();
    return v.clamp(loBin, half);
  });

  // Precompute the Hann window once.
  final hann = Float64List(win);
  for (var i = 0; i < win; i++) {
    hann[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / (win - 1));
  }

  final frames = ((nSamples - win) ~/ hop) + 1;
  final out = Float32List(frames * _kVisBars);
  final re = Float64List(win);
  final im = Float64List(win);

  for (var f = 0; f < frames; f++) {
    final start = f * hop;
    for (var i = 0; i < win; i++) {
      re[i] = samples[start + i] * hann[i];
      im[i] = 0.0;
    }
    _fft(re, im);
    final base = f * _kVisBars;
    for (var b = 0; b < _kVisBars; b++) {
      final lo = edges[b];
      final hi = math.max(edges[b + 1], lo + 1);
      var peak = 0.0;
      for (var k = lo; k < hi; k++) {
        // Magnitude normalized by window so it's scale-independent (0..~1).
        final m = math.sqrt(re[k] * re[k] + im[k] * im[k]) / (win / 2);
        if (m > peak) peak = m;
      }
      // sqrt curve lifts ordinary (sub-full-scale) music into a visible swing.
      out[base + b] = math.sqrt((peak / 0.22).clamp(0.0, 1.0)).toDouble();
    }
  }
  return _SpectroResult(out, frames, fps);
}

// In-place iterative radix-2 Cooley–Tukey FFT. Length must be a power of two.
void _fft(Float64List re, Float64List im) {
  final n = re.length;
  for (var i = 1, j = 0; i < n; i++) {
    var bit = n >> 1;
    for (; (j & bit) != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      var t = re[i];
      re[i] = re[j];
      re[j] = t;
      t = im[i];
      im[i] = im[j];
      im[j] = t;
    }
  }
  for (var len = 2; len <= n; len <<= 1) {
    final ang = -2 * math.pi / len;
    final wlenR = math.cos(ang), wlenI = math.sin(ang);
    final half = len >> 1;
    for (var i = 0; i < n; i += len) {
      var wR = 1.0, wI = 0.0;
      for (var k = 0; k < half; k++) {
        final aR = re[i + k], aI = im[i + k];
        final bR = re[i + k + half] * wR - im[i + k + half] * wI;
        final bI = re[i + k + half] * wI + im[i + k + half] * wR;
        re[i + k] = aR + bR;
        im[i + k] = aI + bI;
        re[i + k + half] = aR - bR;
        im[i + k + half] = aI - bI;
        final nwR = wR * wlenR - wI * wlenI;
        wI = wR * wlenI + wI * wlenR;
        wR = nwR;
      }
    }
  }
}
