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
import 'package:shared_preferences/shared_preferences.dart';

import '../api/lymnal_client.dart';
import '../util/lymnal_host.dart';

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
  // Set when playing a trove stream (not the asset playlist); overrides the
  // shown title and hides the playlist index.
  String? _override;

  // --- trove folder playlist + double-buffered preload ---
  // Streaming from a trove folder plays that whole folder as a playlist: when a
  // track ends the next file in the SAME folder plays (never the easter-egg
  // soundtrack), and near the end of each track the next one is fetched ahead
  // into the other temp "slot" so the gap between songs is short. Two slots are
  // reused round-robin, so only ~2 tracks' worth of temp files ever exist.
  LymnalClient? _troveClient;
  List<(String, String)> _troveQueue = const []; // (full trove path, name)
  int _troveIndex = -1;
  int _curSlot = 0; // temp slot holding the current track (0 or 1)
  int _preloadedIndex = -1; // queue index sitting ready in the other slot
  String? _preloadedPath; // its prepared, ready-to-play file
  bool _preloading = false;
  final List<List<String>> _slotTemp = [<String>[], <String>[]];
  bool _loadingTrove = false; // a user-tapped track is being fetched/prepared

  // Playback volume (0..1), applied to every source and remembered across
  // launches. _preMute holds the level to come back to when unmuting.
  static const _volKey = 'music.volume';
  double _volume = 1.0;
  double _preMute = 1.0;

  // ---- real-time visualizer ----
  // The bars are the real FFT of the real audio at the exact play instant —
  // computed ON DEMAND, one window at a time, straight from the playing track's
  // PCM at the play head. Nothing is precomputed and nothing is kept: just an
  // open handle to the current track's samples (a WAV) and the single most
  // recent frame of bars (shared by the deck, the woofers and the edge light).
  // So a new track has bars on its first frame, and only the moment being played
  // is ever touched — it fits streaming. Not a speaker capture (that lags a
  // buffer); the real samples, read at the position they're being heard.
  RandomAccessFile? _pcm; // current track's decoded audio (a WAV), open for reads
  int _pcmDataOffset = 0; // byte offset of the 'data' chunk
  int _pcmRate = 44100;
  int _pcmChannels = 2;
  int _pcmFrames = 0; // total sample-frames
  File? _pcmTemp; // a WAV we decoded just for this (delete on close); null if reusing one
  int _analysisToken = 0; // so a slow decode for an old track can't open over a newer one
  int _lastBarsBucket = -1; // memoise the window so 3 widgets share one FFT per frame
  List<double> _lastBars = const <double>[];

  // A wall-clock play-head for the visualizer. audioplayers' position events can
  // go sparse or stall on Android — if the bars sampled `_pos` directly they'd
  // freeze mid-song (and the woofers and edge light with them). So anchor to the
  // last real position event and extrapolate with a Stopwatch between events, so
  // the reactive system keeps moving even when events dry up. Resynced on every
  // real event, seek, and track change.
  final Stopwatch _visClock = Stopwatch();
  Duration _visAnchor = Duration.zero;

  /// Re-anchor the visualizer play-head to a known position.
  void _anchorVis(Duration at) {
    _visAnchor = at;
    _visClock.reset();
    if (_playing) {
      _visClock.start();
    } else {
      _visClock.stop();
    }
  }

  /// The extrapolated play position for the visualizer (real anchor + elapsed).
  Duration get _visPos => _playing
      ? _visAnchor + Duration(microseconds: _visClock.elapsedMicroseconds)
      : _visAnchor;

  MusicController() {
    _player.onPositionChanged.listen((d) {
      _pos = d;
      _anchorVis(d);
      _maybePreload(); // fetch the next trove track ahead as this one nears its end
      notifyListeners();
    });
    _player.onDurationChanged.listen((d) {
      _dur = d;
      notifyListeners();
    });
    _player.onPlayerStateChanged.listen((s) {
      _playing = s == PlayerState.playing;
      if (_playing) {
        if (!_visClock.isRunning) _visClock.start();
      } else {
        _visClock.stop();
      }
      notifyListeners();
    });
    _player.onPlayerComplete.listen((_) => _onComplete());
    _load();
    _restoreVolume();
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
  bool get loadingTrove => _loadingTrove;
  bool get active => _hasSource && (_playing || _pos > Duration.zero);
  double get volume => _volume;
  bool get muted => _volume <= 0;

  Future<void> _restoreVolume() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _volume = (prefs.getDouble(_volKey) ?? 1.0).clamp(0.0, 1.0);
    } catch (_) {}
    if (_volume > 0) _preMute = _volume;
    try {
      await _player.setVolume(_volume);
    } catch (_) {}
    notifyListeners();
  }

  /// Set the playback volume (0..1) and remember it. Applies live.
  Future<void> setVolume(double v) async {
    _volume = v.clamp(0.0, 1.0);
    if (_volume > 0) _preMute = _volume;
    try {
      await _player.setVolume(_volume);
    } catch (_) {}
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_volKey, _volume);
    } catch (_) {}
  }

  /// Nudge the volume by [delta] — what the mouse wheel over the deck drives.
  Future<void> nudgeVolume(double delta) => setVolume(_volume + delta);

  /// Mute, or return to the level from before muting (clicking the speaker).
  Future<void> toggleMute() =>
      setVolume(_volume > 0 ? 0.0 : (_preMute > 0 ? _preMute : 0.5));

  /// Number of spectrum bars the analysis produces (and the visualizer draws).
  static const int kVisBars = _kVisBars;

  /// The spectrum bars (0..1) for the current play position — the real FFT of
  /// the real audio at exactly this instant, computed on the spot from the
  /// window of samples at the play head. Empty (bars rest) when there's nothing
  /// to read. Memoised per ~5ms so the deck, woofers and edge light share one
  /// FFT per frame instead of each doing their own.
  List<double> visualizerBars() {
    final raf = _pcm;
    final n = _pcmFrames;
    if (raf == null || n <= 0) return const <double>[];
    var start = (_visPos.inMicroseconds * _pcmRate / 1000000.0).floor();
    if (start < 0) start = 0;
    if (start >= n) start = n - 1;
    final bucket = start >> 8; // ~256 samples ≈ 5ms at 48k
    if (bucket == _lastBarsBucket) return _lastBars;
    _lastBarsBucket = bucket;
    _lastBars = _frameBars(raf, start);
    return _lastBars;
  }

  /// Read the [_win]-sample window at [startSample] straight from the open WAV,
  /// down-mix to mono, and turn it into the bar levels. Synchronous — a couple of
  /// KB read plus one small FFT, cheap enough to run per frame on the UI thread.
  List<double> _frameBars(RandomAccessFile raf, int startSample) {
    final ch = _pcmChannels;
    final bytesPerFrame = ch * 2;
    try {
      raf.setPositionSync(_pcmDataOffset + startSample * bytesPerFrame);
      final raw = raf.readSync(_win * bytesPerFrame);
      if (raw.length < bytesPerFrame) return const <double>[];
      final avail = raw.length ~/ bytesPerFrame;
      final bd = ByteData.sublistView(raw);
      final re = Float64List(_win);
      final im = Float64List(_win);
      for (var i = 0; i < _win; i++) {
        if (i < avail) {
          var sum = 0;
          for (var c = 0; c < ch; c++) {
            sum += bd.getInt16((i * ch + c) * 2, Endian.little);
          }
          re[i] = (sum / ch) / 32768.0 * _hann[i];
        } else {
          re[i] = 0.0; // zero-pad the tail at end of file
        }
        im[i] = 0.0;
      }
      _fft(re, im);
      return _bands(re, im);
    } catch (_) {
      return const <double>[];
    }
  }

  /// Point the visualizer at a track's PCM. A WAV is opened directly; anything
  /// else is decoded to a throwaway WAV first — ffmpeg on desktop, the native
  /// MediaCodec decoder on Android — so the bars have real samples on every
  /// platform. Holds nothing but the open handle; the previous track's handle
  /// (and any temp) is released.
  Future<void> _openAnalysis(String path) async {
    await _closeAnalysis(); // bumps the token; capture ours after
    final token = ++_analysisToken;
    String wavPath = path;
    File? temp;
    if (!path.toLowerCase().endsWith('.wav')) {
      final dir = await getTemporaryDirectory();
      final out = '${dir.path}/elyxr_vis_${path.hashCode & 0x7fffffff}.wav';
      if (Platform.isAndroid) {
        // No ffmpeg on a phone — decode to PCM natively so the bars have real
        // samples to read (m4a trove streams already arrive as WAV via
        // _audioOnly, but mp3/ogg/etc. reach here compressed).
        final ok = await LymnalHost.decodeToWav(path, out);
        if (!ok) return;
      } else {
        try {
          final r = await Process.run(_mediaBin('ffmpeg'),
              ['-y', '-v', 'error', '-i', path, '-ac', '2', '-ar', '44100', out]);
          if (r.exitCode != 0 || !File(out).existsSync()) return;
        } catch (_) {
          return;
        }
      }
      wavPath = out;
      temp = File(out);
    }
    if (token != _analysisToken) {
      temp?.delete().ignore();
      return; // a newer track already took over
    }
    final info = _wavHeader(wavPath);
    if (info == null) {
      temp?.delete().ignore();
      return;
    }
    _pcm = File(wavPath).openSync();
    _pcmDataOffset = info.dataOffset;
    _pcmRate = info.rate;
    _pcmChannels = info.channels;
    _pcmFrames = info.frames;
    _pcmTemp = temp;
    _lastBarsBucket = -1;
    _lastBars = const <double>[];
  }

  /// Close the current analysis handle and delete any temp WAV we made for it.
  Future<void> _closeAnalysis() async {
    _analysisToken++;
    try {
      _pcm?.closeSync();
    } catch (_) {}
    _pcm = null;
    _pcmFrames = 0;
    _lastBarsBucket = -1;
    _lastBars = const <double>[];
    final t = _pcmTemp;
    _pcmTemp = null;
    if (t != null) t.delete().ignore();
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
    // Leaving trove-playlist mode for the asset soundtrack — drop the queue (and
    // its preload) so a completing track egg-shuffles instead of advancing it.
    _troveQueue = const [];
    _troveIndex = -1;
    _preloadedIndex = -1;
    _preloadedPath = null;
    _freeSlot(0);
    _freeSlot(1);
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

  /// Turn the demo soundtrack off now (2000's DEMO MODE switched off) — but only
  /// if that easter-egg soundtrack is what's playing; a trove stream is left be.
  Future<void> stopBuiltIn() async {
    if (_playing && !isStream) await stopPlayback();
  }

  /// Stop playback entirely and return the player to its resting state — from
  /// here it only plays again when the user picks a trove file (or Nostalgia
  /// restarts the soundtrack). Clears the easter-egg shuffle too.
  Future<void> stopPlayback() async {
    _nostalgiaStop?.cancel();
    _eggShuffle = false;
    // Clear the trove playlist + preload and free both temp slots.
    _troveQueue = const [];
    _troveIndex = -1;
    _preloadedIndex = -1;
    _preloadedPath = null;
    _loadingTrove = false;
    _freeSlot(0);
    _freeSlot(1);
    try {
      await _player.stop();
    } catch (_) {}
    _playing = false;
    _hasSource = false;
    _override = null;
    _pos = Duration.zero;
    _closeAnalysis(); // release the visualizer handle; bars rest
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

  // Containers that can hide a video track behind an "audio" extension — an
  // .m4a that's really an MP4 with video. Handed one, the platform's media
  // backend renders the video too (a GStreamer video window on Linux; a surface
  // on Android). We only ever want sound, so these get stripped to audio first.
  static const _videoCapableExts = {'m4a', 'mp4', 'm4v', 'mov'};

  /// Return a path with the video track removed for a container that might carry
  /// one, so the player never has a picture to show; anything else is returned
  /// untouched. Desktop copies the audio track out with ffmpeg (no re-encode,
  /// falling back to a WAV decode); Android decodes it to a PCM WAV natively
  /// (MediaExtractor/MediaCodec), which carries no video and also feeds the
  /// visualizer. If no decoder is available or it fails, the original path is
  /// returned (audio still plays — a video window may appear).
  Future<String> _audioOnly(String path, String ext, String tag) async {
    if (!_videoCapableExts.contains(ext.toLowerCase())) return path;
    final dir = await getTemporaryDirectory();
    // [tag] keeps each track's temp file distinct, so a preloaded next track
    // never overwrites the one currently playing.
    if (Platform.isAndroid) {
      // No ffmpeg on a phone: decode natively to a PCM WAV. It has no video
      // track (nothing to render) and doubles as the visualizer's input, so the
      // lightshow works too. Falls back to the original if the decode fails.
      final wavOut = '${dir.path}/elyxr_aud_$tag.wav';
      final ok = await LymnalHost.decodeToWav(path, wavOut);
      return ok ? wavOut : path;
    }
    final m4aOut = '${dir.path}/elyxr_aud_$tag.m4a';
    try {
      final r = await Process.run(_mediaBin('ffmpeg'),
          ['-y', '-v', 'error', '-i', path, '-vn', '-c:a', 'copy', m4aOut]);
      if (r.exitCode == 0 && File(m4aOut).existsSync()) return m4aOut;
    } catch (_) {
      // ffmpeg missing — nothing to try below either; fall through.
      return path;
    }
    // Copy failed (an audio codec MP4 can't hold): decode to a plain WAV, which
    // also can't carry video. WAV feeds the visualizer directly too.
    final wavOut = '${dir.path}/elyxr_aud_$tag.wav';
    try {
      final r = await Process.run(_mediaBin('ffmpeg'),
          ['-y', '-v', 'error', '-i', path, '-vn', '-ac', '2', '-ar', '44100', wavOut]);
      if (r.exitCode == 0 && File(wavOut).existsSync()) return wavOut;
    } catch (_) {}
    return path;
  }

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

  /// Render a tracker module to a temp WAV so it can be played like any other
  /// file (and analysed for the visualizer). Cached by input path; returns the
  /// original path if no renderer is available. Desktop shells out to
  /// openmpt123/ffmpeg; Android execs the bundled libopenmpt renderer
  /// (libmodrender.so) from its native-lib dir — a phone has no system binaries.
  Future<String> _renderModule(String inPath, String ext) async {
    final dir = await getTemporaryDirectory();
    final out = '${dir.path}/elyxr_mod_${inPath.hashCode & 0x7fffffff}.wav';
    if (File(out).existsSync()) return out;
    if (Platform.isAndroid) {
      final libDir = await LymnalHost.nativeLibDir();
      if (libDir != null) {
        try {
          final r = await Process.run(
            '$libDir/libmodrender.so',
            [inPath, out],
            environment: {'LD_LIBRARY_PATH': libDir},
          );
          if (r.exitCode == 0 && File(out).existsSync()) return out;
        } catch (_) {
          // renderer missing/failed — fall through
        }
      }
      return inPath;
    }
    final attempts = <List<String>>[
      [_mediaBin('openmpt123'), '--quiet', '--force', '--render', '-o', out, inPath],
      [_mediaBin('ffmpeg'), '-y', '-loglevel', 'error', '-i', inPath, out],
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
      await _player.play(src, volume: _volume);
      _hasSource = true;
      _playing = true;
      _anchorVis(Duration.zero); // restart the visualizer play-head
      _openAnalysis(analysisPath); // point the on-demand visualizer at this track
    } catch (_) {
      _playing = false;
    }
    notifyListeners();
  }

  /// Stream a trove folder as a playlist. [queue] is the folder's audio files
  /// (full trove path + display name) in list order; [index] is the tapped one
  /// to start on. From here the folder auto-advances and preloads (see
  /// _onComplete / _maybePreload). Works for any folder, nested or not — the
  /// caller passes whatever folder is being browsed.
  Future<void> playTroveQueue(
      LymnalClient client, List<(String, String)> queue, int index) async {
    _troveClient = client;
    _troveQueue = queue;
    _eggShuffle = false; // a real pick ends the easter-egg auto-shuffle
    _preloadedIndex = -1;
    _preloadedPath = null;
    _loadingTrove = true; // show the spinner the instant the row is tapped
    notifyListeners();
    await _freeSlot(0);
    await _freeSlot(1);
    await _playTroveIndex(index, 0);
  }

  /// Fetch + prepare queue entry [i] into [slot] and play it. This is the path
  /// that shows the loading indicator; a preloaded advance skips it.
  Future<void> _playTroveIndex(int i, int slot) async {
    final client = _troveClient;
    if (client == null || i < 0 || i >= _troveQueue.length) return;
    _troveIndex = i;
    _curSlot = slot;
    _loadingTrove = true;
    notifyListeners();
    final (path, name) = _troveQueue[i];
    final playable = await _prepareSlot(client, path, slot);
    _loadingTrove = false;
    if (playable == null) {
      _playing = false;
      notifyListeners();
      return;
    }
    await _startFile(playable, name);
    _maybePreload();
  }

  /// Play an already-prepared file as the current trove track — shared by the
  /// initial play and a preloaded advance.
  Future<void> _startFile(String playable, String name) async {
    try {
      await _player.stop();
      await _player.play(DeviceFileSource(playable), volume: _volume);
      _override = _pretty(name);
      _hasSource = true;
      _pos = Duration.zero;
      _playing = true;
      _anchorVis(Duration.zero); // restart the visualizer play-head
      _openAnalysis(playable); // point the on-demand visualizer at this track
    } catch (_) {
      _playing = false;
    }
    notifyListeners();
  }

  /// The current trove track ended: play the next file in the folder. Uses the
  /// preloaded track instantly if it's ready, else fetches it; stops at the end
  /// of the folder (never falls through to the easter-egg soundtrack).
  Future<void> _advanceTrove() async {
    final next = _troveIndex + 1;
    if (next >= _troveQueue.length) {
      await stopPlayback(); // end of folder — rest, don't start the egg music
      return;
    }
    if (_preloadedIndex == next && _preloadedPath != null) {
      final slot = 1 - _curSlot;
      _troveIndex = next;
      _curSlot = slot;
      final ready = _preloadedPath!;
      final (_, name) = _troveQueue[next];
      _preloadedIndex = -1;
      _preloadedPath = null;
      await _startFile(ready, name);
      _maybePreload();
    } else {
      await _playTroveIndex(next, 1 - _curSlot);
    }
  }

  /// Fetch + prepare the next track into the other slot as soon as the current
  /// one starts playing, so a straight play-through or a skip begins fast. Only
  /// ever ONE track ahead (the other half of the double buffer), so the preload
  /// can't pile up no matter how long the queue is. Best-effort and idempotent:
  /// it's called on every position tick but does real work only once per track.
  void _maybePreload() {
    if (_troveQueue.isEmpty || _troveIndex < 0 || _preloading) return;
    final next = _troveIndex + 1;
    if (next >= _troveQueue.length || _preloadedIndex == next) return;
    final client = _troveClient;
    if (client == null) return;
    _preloading = true;
    final slot = 1 - _curSlot;
    final target = next;
    final (path, _) = _troveQueue[next];
    _prepareSlot(client, path, slot).then((playable) {
      _preloading = false;
      // Keep it only if we're still on the same current track.
      if (playable != null && _troveIndex + 1 == target) {
        _preloadedIndex = target;
        _preloadedPath = playable;
      }
    });
  }

  /// Download [path] and prepare a playable file in [slot] (double-buffered: one
  /// slot for the current track, the other for the preloaded next, swapping as
  /// we advance). Frees the slot's previous temp files first, so only ~2 tracks'
  /// worth of temp ever exists. Returns the playable path, or null on failure.
  Future<String?> _prepareSlot(LymnalClient client, String path, int slot) async {
    await _freeSlot(slot);
    try {
      final bytes = await client.downloadBytes(path);
      final dir = await getTemporaryDirectory();
      final dot = path.lastIndexOf('.');
      final ext = dot >= 0 ? path.substring(dot + 1).toLowerCase() : '';
      final raw = File('${dir.path}/elyxr_slot$slot.$ext');
      await raw.writeAsBytes(bytes, flush: true);
      _slotTemp[slot].add(raw.path);
      final String playable;
      if (_isModule(ext)) {
        playable = await _renderModule(raw.path, ext);
      } else {
        // Strip any video track (an .m4a that's really an MP4) so only sound
        // plays — no picture window on any platform.
        playable = await _audioOnly(raw.path, ext, 'slot$slot');
      }
      if (playable != raw.path) _slotTemp[slot].add(playable);
      return playable;
    } catch (_) {
      return null;
    }
  }

  /// Delete a slot's temp files — the tracked ones, plus any stray slot-named
  /// leftovers (e.g. an intermediate from _audioOnly's fallback).
  Future<void> _freeSlot(int slot) async {
    for (final t in _slotTemp[slot]) {
      File(t).delete().ignore();
    }
    _slotTemp[slot] = [];
    try {
      final dir = await getTemporaryDirectory();
      for (final f in dir.listSync().whereType<File>()) {
        final n = f.path.split(Platform.pathSeparator).last;
        if (n.startsWith('elyxr_slot$slot.') ||
            n.startsWith('elyxr_aud_slot$slot')) {
          f.delete().ignore();
        }
      }
    } catch (_) {}
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
    // Streaming a trove folder: the folder IS the playlist — play the next file
    // in it (stopping at the end), never the easter-egg soundtrack.
    if (_troveQueue.isNotEmpty && _troveIndex >= 0) {
      _advanceTrove();
      return;
    }
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
      _anchorVis(to);
      notifyListeners();
    } catch (_) {}
  }

  @override
  void dispose() {
    _closeAnalysis(); // close the visualizer handle, drop any temp
    _freeSlot(0);
    _freeSlot(1);
    _nostalgiaStop?.cancel();
    _player.dispose();
    super.dispose();
  }
}

// ---- on-demand visualizer analysis ----

const int _kVisBars = 28;
const int _win = 1024; // FFT window (power of two)

/// Hann window over one FFT frame, computed once.
final Float64List _hann = () {
  final h = Float64List(_win);
  for (var i = 0; i < _win; i++) {
    h[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / (_win - 1));
  }
  return h;
}();

/// The log-spaced FFT-bin edges each bar spans, computed once.
final List<int> _edges = () {
  const half = _win ~/ 2;
  const loBin = 2;
  final hiBin = (half - 1).clamp(loBin + 1, half);
  return List<int>.generate(_kVisBars + 1, (b) {
    final v = (loBin * math.pow(hiBin / loBin, b / _kVisBars)).round();
    return v.clamp(loBin, half);
  });
}();

/// One FFT frame (re/im of length [_win]) → the [_kVisBars] bar levels (0..1).
List<double> _bands(Float64List re, Float64List im) {
  return List<double>.generate(_kVisBars, (b) {
    final lo = _edges[b];
    final hi = math.max(_edges[b + 1], lo + 1);
    var peak = 0.0;
    for (var k = lo; k < hi; k++) {
      // Magnitude normalized by window so it's scale-independent (0..~1).
      final m = math.sqrt(re[k] * re[k] + im[k] * im[k]) / (_win / 2);
      if (m > peak) peak = m;
    }
    // sqrt curve lifts ordinary (sub-full-scale) music into a visible swing.
    return math.sqrt((peak / 0.22).clamp(0.0, 1.0)).toDouble();
  });
}

/// The path to a media helper (ffmpeg / openmpt123). On Windows they ship beside
/// the app executable; on Linux they come from the system (on PATH).
String _mediaBin(String name) {
  if (Platform.isWindows) {
    final beside =
        File('${File(Platform.resolvedExecutable).parent.path}\\$name.exe');
    return beside.existsSync() ? beside.path : '$name.exe';
  }
  return name;
}

/// Where a 16-bit PCM WAV's audio starts and its shape — without reading the
/// audio body, so the visualizer can seek to any window on demand. Walks the
/// RIFF chunks (the header + chunk table live in the first few KB).
class _WavInfo {
  final int dataOffset;
  final int rate;
  final int channels;
  final int frames;
  const _WavInfo(this.dataOffset, this.rate, this.channels, this.frames);
}

_WavInfo? _wavHeader(String path) {
  try {
    final raf = File(path).openSync();
    try {
      final head = raf.readSync(4096);
      if (head.length < 12) return null;
      final bd = ByteData.sublistView(head);
      String tag(int o) => String.fromCharCodes(head.sublist(o, o + 4));
      if (tag(0) != 'RIFF' || tag(8) != 'WAVE') return null;

      int channels = 0, rate = 0, bits = 0, dataOff = -1, dataLen = 0, fmt = 0;
      var p = 12;
      while (p + 8 <= head.length) {
        final id = tag(p);
        final sz = bd.getUint32(p + 4, Endian.little);
        final body = p + 8;
        if (id == 'fmt ' && body + 16 <= head.length) {
          fmt = bd.getUint16(body, Endian.little);
          channels = bd.getUint16(body + 2, Endian.little);
          rate = bd.getUint32(body + 4, Endian.little);
          bits = bd.getUint16(body + 14, Endian.little);
        } else if (id == 'data') {
          dataOff = body;
          dataLen = sz;
          break; // the audio body follows; stop walking
        }
        p = body + sz + (sz & 1); // chunks are word-aligned
      }
      if (fmt != 1 || bits != 16 || channels < 1 || rate <= 0 || dataOff < 0) {
        return null;
      }
      final fileLen = raf.lengthSync();
      final end = dataLen > 0 ? math.min(dataOff + dataLen, fileLen) : fileLen;
      final frames = (end - dataOff) ~/ (channels * 2);
      return _WavInfo(dataOff, rate, channels, frames);
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return null;
  }
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
