// The music player, on media_kit (libmpv — the same backend the inline video
// preview already uses). Plays whatever is in assets/music/ plus any audio file
// in the trove. A trove folder is handed to the player as a real playlist of
// SOURCES, not of downloaded files: on the server device that source is the file
// on this disk, and over the network it's the /v1/download URL, which lymnal
// serves with Range honoured. So the backend buffers natively and a tap starts
// playing on the first chunk instead of the last one — nothing waits for a whole
// file any more.
//
// Two consequences worth knowing. mpv owns the playlist, so advance, prefetch,
// shuffle and the loop modes are its job, not ours — there is no download queue
// or temp-slot bookkeeping in here. And video is never decoded or shown: the
// player is built with no video output and each media has its video track
// switched off, so an .m4a that's really an MP4 plays as sound and nothing else.
//
// mp3/ogg/wav/flac/m4a play directly; tracker modules (.xm/.mod/.s3m/.it) are
// rendered to WAV on load (openmpt123) first. Playback never depends on the
// visualizer — that's a separate concern entirely (see _openAnalysis).

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/lymnal_client.dart';
import '../util/lymnal_host.dart';

/// Audio extensions the player accepts — common formats libmpv decodes directly,
/// plus tracker modules (.xm/.mod/.s3m/.it) which are rendered to PCM on load
/// (see _renderModule) so they play too.
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

  // No video output is ever created for this player (PlayerConfiguration.vo
  // defaults to 'null'), so the deck can never sprout a picture — the video
  // track is switched off per media as well, so it isn't even decoded.
  final Player _player = Player(
    configuration: const PlayerConfiguration(title: 'Elyxr'),
  );
  final List<StreamSubscription<dynamic>> _subs = [];

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

  // --- trove folder playlist ---
  // Streaming from a trove folder plays that whole folder: the folder's audio
  // files become one playlist handed to mpv, which advances and prefetches on its
  // own. _byUri maps a media back to its (trove path, display name) so the title,
  // the tracklist and the visualizer stay correct even after a shuffle reorders
  // the playlist under us.
  LymnalClient? _troveClient;
  bool _trove = false; // the folder playlist is what's loaded (not the assets)
  List<(String, String)> _troveQueue = const []; // (full trove path, name)
  final Map<String, (String, String)> _byUri = {};
  Playlist? _plist; // the player's live playlist (post-shuffle order)
  bool _opening = false; // a tapped track is being opened, before mpv reports in
  bool _buffering = false; // mpv is filling its buffer for the current track
  // Which media the visualizer is already working on, so opening a folder (which
  // both calls _pointAnalysisAtCurrent and gets a playlist event) fetches once.
  String? _analysisUri;

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
  //
  // This is now the ONLY thing that ever needs a local copy, and it is
  // deliberately off the critical path: sound starts from the stream while the
  // samples are still being fetched, and the bars join a moment later. They can't
  // drift when they do, because the read offset is derived from the position in
  // the TRACK's timeline (see visualizerBars), not from anything about how or
  // when the bytes arrived.
  RandomAccessFile? _pcm; // current track's decoded audio (a WAV), open for reads
  int _pcmDataOffset = 0; // byte offset of the 'data' chunk
  int _pcmRate = 44100;
  int _pcmChannels = 2;
  int _pcmFrames = 0; // total sample-frames
  // Temp files this analysis owns and must delete when it closes — a fetched
  // copy of a remote track and/or the WAV we decoded from it. Never contains a
  // file that something is playing from.
  List<String> _pcmTemps = const [];
  int _analysisToken = 0; // so a slow fetch/decode can't open over a newer track
  int _lastBarsBucket = -1; // memoise the window so 3 widgets share one FFT per frame
  List<double> _lastBars = const <double>[];

  // A wall-clock play-head for the visualizer. Position events can go sparse or
  // stall — if the bars sampled `_pos` directly they'd freeze mid-song (and the
  // woofers and edge light with them). So anchor to the last real position event
  // and extrapolate with a Stopwatch between events, so the reactive system keeps
  // moving even when events dry up. Resynced on every real event, seek, and track
  // change.
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
    final s = _player.stream;
    _subs.add(s.position.listen((d) {
      _pos = d;
      _anchorVis(d);
      notifyListeners();
    }));
    _subs.add(s.duration.listen((d) {
      _dur = d;
      notifyListeners();
    }));
    _subs.add(s.playing.listen((p) {
      _playing = p;
      if (p) {
        _opening = false;
        if (!_visClock.isRunning) _visClock.start();
      } else {
        _visClock.stop();
      }
      notifyListeners();
    }));
    _subs.add(s.buffering.listen((b) {
      _buffering = b;
      if (!b) _opening = false;
      notifyListeners();
    }));
    // mpv owns the playlist, so an advance shows up here as an index change —
    // that's the signal to retitle and re-point the visualizer.
    _subs.add(s.playlist.listen((pl) {
      final was = _plist?.index;
      _plist = pl;
      if (_trove && pl.index != was) {
        _pos = Duration.zero;
        _anchorVis(Duration.zero);
        _pointAnalysisAtCurrent();
      }
      notifyListeners();
    }));
    _subs.add(s.completed.listen((done) {
      if (done) _onComplete();
    }));
    _load();
    _restoreVolume();
  }

  List<String> get tracks => _tracks;
  bool get hasTracks => _tracks.isNotEmpty;
  bool get playing => _playing;
  bool get shuffle => _shuffle;
  MusicRepeat get repeat => _repeat;
  Duration get position => _pos;
  Duration get duration => _dur;
  bool get isStream => _trove;
  bool get active => _hasSource && (_playing || _pos > Duration.zero);
  double get volume => _volume;
  bool get muted => _volume <= 0;

  /// True while the current track is still being opened or buffered — real
  /// feedback now, rather than a wait for a whole file.
  bool get loadingTrove => _opening || _buffering;

  /// How many tracks the active list holds — the trove folder while one is
  /// playing, else the built-in soundtrack.
  int get count => _trove
      ? (_plist?.medias.length ?? _troveQueue.length)
      : _tracks.length;

  /// Which track of the active list is playing. In trove mode this comes from the
  /// player, so it stays right after mpv advances or a shuffle reorders things.
  int get index => _trove ? (_plist?.index ?? 0) : _index;

  String get title {
    if (!_trove) return hasTracks ? _pretty(_tracks[_index]) : 'no tracks';
    return titleAt(index);
  }

  String titleAt(int i) {
    if (!_trove) {
      return i >= 0 && i < _tracks.length ? _pretty(_tracks[i]) : '';
    }
    final medias = _plist?.medias;
    if (medias != null && i >= 0 && i < medias.length) {
      final hit = _byUri[medias[i].uri];
      if (hit != null) return _pretty(hit.$2);
    }
    // Before the first playlist event, fall back to the order we handed over.
    return i >= 0 && i < _troveQueue.length ? _pretty(_troveQueue[i].$2) : '';
  }

  Future<void> _restoreVolume() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _volume = (prefs.getDouble(_volKey) ?? 1.0).clamp(0.0, 1.0);
    } catch (_) {}
    if (_volume > 0) _preMute = _volume;
    await _pushVolume();
    notifyListeners();
  }

  // media_kit takes volume as 0..100, not 0..1.
  Future<void> _pushVolume() async {
    try {
      await _player.setVolume(_volume * 100);
    } catch (_) {}
  }

  /// Set the playback volume (0..1) and remember it. Applies live.
  Future<void> setVolume(double v) async {
    _volume = v.clamp(0.0, 1.0);
    if (_volume > 0) _preMute = _volume;
    await _pushVolume();
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
  /// to read, which is also what a track shows while its samples are still being
  /// fetched. Memoised per ~5ms so the deck, woofers and edge light share one FFT
  /// per frame instead of each doing their own.
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

  /// Point the visualizer at whatever the player is playing now. The samples come
  /// from the trove file itself on the server device, and from a background fetch
  /// over the network — so this NEVER blocks playback, and a track change part way
  /// through simply abandons the work (the token check).
  void _pointAnalysisAtCurrent() {
    final pl = _plist;
    if (pl == null || pl.index < 0 || pl.index >= pl.medias.length) return;
    final uri = pl.medias[pl.index].uri;
    if (uri == _analysisUri) return; // already fetching/analysing this one
    // Normally the media maps straight back to its trove entry. If the player
    // hands the URI back in a form we don't recognise, fall back to position —
    // valid as long as the playlist still matches the folder we handed over.
    final hit = _byUri[uri] ??
        (pl.medias.length == _troveQueue.length && !_shuffle
            ? _troveQueue[pl.index]
            : null);
    if (hit == null) return;
    final trovePath = hit.$1;
    _analysisUri = uri;
    final token = ++_analysisToken;
    () async {
      await _closeAnalysis();
      final fetched = await _fetchForAnalysis(trovePath, token);
      if (fetched == null) return;
      final (path, owned) = fetched;
      if (token != _analysisToken) {
        _sweep(owned);
        return;
      }
      await _openAnalysis(path, token, temps: owned);
      notifyListeners();
    }();
  }

  /// Get a local copy of [trovePath] for analysis: the file itself when the trove
  /// is on this machine (nothing to fetch, nothing owned), else a temp download.
  /// Returns the path plus the temp files the caller now owns, or null on failure
  /// or if a newer track took over mid-fetch.
  Future<(String, List<String>)?> _fetchForAnalysis(
      String trovePath, int token) async {
    final client = _troveClient;
    if (client == null) return null;
    final local = client.localPathFor(trovePath);
    if (local != null && File(local).existsSync()) {
      return (local, const <String>[]); // the trove file; not ours to delete
    }
    final dot = trovePath.lastIndexOf('.');
    final ext = dot >= 0 ? trovePath.substring(dot + 1).toLowerCase() : 'bin';
    try {
      final dir = await getTemporaryDirectory();
      final f = File(
          '${dir.path}/elyxr_vis_src_${trovePath.hashCode & 0x7fffffff}.$ext');
      final sink = f.openWrite();
      try {
        await client.downloadTo(trovePath, sink,
            cancelled: () => token != _analysisToken);
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (token != _analysisToken) {
        f.delete().ignore();
        return null;
      }
      return (f.path, <String>[f.path]);
    } catch (_) {
      return null;
    }
  }

  /// Open [path]'s PCM for the visualizer. A WAV is read directly; anything else
  /// is decoded to a throwaway WAV first — ffmpeg on desktop, the native
  /// MediaCodec decoder on Android. [temps] are files the caller already owns
  /// (a fetched copy); the decoded WAV joins them, and all of them are deleted
  /// when the analysis closes. Holds nothing but the open handle.
  Future<void> _openAnalysis(String path, int token,
      {List<String> temps = const []}) async {
    final owned = <String>[...temps];
    var wavPath = path;
    if (!path.toLowerCase().endsWith('.wav')) {
      final dir = await getTemporaryDirectory();
      final out = '${dir.path}/elyxr_vis_${path.hashCode & 0x7fffffff}.wav';
      if (Platform.isAndroid) {
        // No ffmpeg on a phone — decode to PCM natively so the bars have real
        // samples to read.
        if (!await LymnalHost.decodeToWav(path, out)) {
          _sweep(owned);
          return;
        }
      } else {
        try {
          final r = await Process.run(_mediaBin('ffmpeg'),
              ['-y', '-v', 'error', '-i', path, '-ac', '2', '-ar', '44100', out]);
          if (r.exitCode != 0 || !File(out).existsSync()) {
            _sweep(owned);
            return;
          }
        } catch (_) {
          _sweep(owned);
          return;
        }
      }
      wavPath = out;
      owned.add(out);
    }
    if (token != _analysisToken) {
      _sweep(owned); // a newer track already took over
      return;
    }
    final info = _wavHeader(wavPath);
    if (info == null) {
      _sweep(owned);
      return;
    }
    try {
      _pcm = File(wavPath).openSync();
    } catch (_) {
      _sweep(owned);
      return;
    }
    _pcmDataOffset = info.dataOffset;
    _pcmRate = info.rate;
    _pcmChannels = info.channels;
    _pcmFrames = info.frames;
    _pcmTemps = owned;
    _lastBarsBucket = -1;
    _lastBars = const <double>[];
  }

  /// Close the current analysis handle and delete the temps it owned.
  Future<void> _closeAnalysis() async {
    try {
      _pcm?.closeSync();
    } catch (_) {}
    _pcm = null;
    _pcmFrames = 0;
    _lastBarsBucket = -1;
    _lastBars = const <double>[];
    final t = _pcmTemps;
    _pcmTemps = const <String>[];
    _sweep(t);
  }

  void _sweep(List<String> paths) {
    for (final p in paths) {
      File(p).delete().ignore();
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
    _trove = false;
    _troveQueue = const [];
    _byUri.clear();
    _plist = null;
    _opening = false;
    _buffering = false;
    try {
      await _player.stop();
    } catch (_) {}
    _playing = false;
    _hasSource = false;
    _pos = Duration.zero;
    _analysisToken++; // abandon any in-flight fetch/decode
    _analysisUri = null;
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

  /// Extract a bundled asset to a real file the player can open, rendering a
  /// tracker module to WAV on the way. Cached by asset key, so switching back to
  /// a track doesn't re-extract it.
  Future<String> _assetFile(String assetKey) async {
    final ext = assetKey.split('.').last.toLowerCase();
    final dir = await getTemporaryDirectory();
    final local =
        File('${dir.path}/elyxr_asset_${assetKey.hashCode & 0x7fffffff}.$ext');
    if (!local.existsSync()) {
      final data = await rootBundle.load(assetKey);
      await local.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    if (_isModule(ext)) return _renderModule(local.path, ext);
    return local.path;
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

  /// Play one track of the built-in soundtrack. Leaves trove mode.
  Future<void> playIndex(int i) async {
    if (_tracks.isEmpty) return;
    _index = i % _tracks.length;
    if (_index < 0) _index += _tracks.length;
    _trove = false;
    _troveQueue = const [];
    _byUri.clear();
    _plist = null;
    _pos = Duration.zero;
    _analysisToken++; // abandon anything the previous track had in flight
    _analysisUri = null;
    await _closeAnalysis();
    try {
      final path = await _assetFile(_tracks[_index]);
      // A single media, not a playlist: the easter-egg advance is our own (see
      // _onComplete), so mpv must not loop or advance on its own.
      await _applyRepeat();
      await _player.open(Media(path));
      await _muteVideo();
      _hasSource = true;
      _anchorVis(Duration.zero);
      final token = ++_analysisToken;
      _openAnalysis(path, token); // point the on-demand visualizer at this track
    } catch (_) {
      _playing = false;
    }
    notifyListeners();
  }

  /// Stream a trove folder as a playlist. [queue] is the folder's audio files
  /// (full trove path + display name) in list order; [index] is the tapped one to
  /// start on. Each entry becomes a SOURCE the player opens itself — the file on
  /// disk in server mode, the Range-served download URL over the network — so
  /// playback starts on the first chunk and mpv handles advancing and prefetching
  /// from there. Works for any folder, nested or not.
  Future<void> playTroveQueue(
      LymnalClient client, List<(String, String)> queue, int index) async {
    if (queue.isEmpty) return;
    _troveClient = client;
    _eggShuffle = false; // a real pick ends the easter-egg auto-shuffle
    _nostalgiaStop?.cancel();
    // The tap is authoritative. Drop the old track's analysis handle right here,
    // before any network work happens, so nothing from the previous song is still
    // holding a file or drawing bars while the new one starts.
    _analysisToken++;
    _analysisUri = null;
    await _closeAnalysis();
    _trove = true;
    _troveQueue = queue;
    _plist = null;
    _opening = true; // visible feedback from the instant of the tap
    notifyListeners();

    _byUri.clear();
    final medias = <Media>[];
    for (final (path, name) in queue) {
      final (src, headers) = client.mediaSource(path);
      final media = Media(src, httpHeaders: headers);
      _byUri[media.uri] = (path, name);
      medias.add(media);
    }
    final start = index.clamp(0, medias.length - 1);
    try {
      await _applyRepeat();
      await _player.open(Playlist(medias, index: start));
      await _muteVideo();
      if (_shuffle) {
        try {
          await _player.setShuffle(true);
        } catch (_) {}
      }
      _hasSource = true;
      _anchorVis(Duration.zero);
      _pointAnalysisAtCurrent();
    } catch (_) {
      _opening = false;
      _playing = false;
      _hasSource = false;
      _trove = false;
    }
    notifyListeners();
  }

  /// Switch off the video track for what's loaded. The player has no video output
  /// at all, so this is about not *decoding* a picture we would never show — an
  /// .m4a that's really an MP4 costs nothing extra.
  Future<void> _muteVideo() async {
    try {
      await _player.setVideoTrack(VideoTrack.no());
    } catch (_) {}
  }

  /// Jump to a track of whatever list is active — what the tracklist taps.
  Future<void> playAt(int i) async {
    if (!_trove) return playIndex(i);
    if (i < 0 || i >= count) return;
    try {
      await _player.jump(i);
    } catch (_) {}
  }

  Future<void> toggle() async {
    if (!_hasSource) {
      if (_tracks.isNotEmpty) return playIndex(_index);
      return;
    }
    try {
      await _player.playOrPause();
    } catch (_) {}
  }

  void toggleShuffle() {
    _shuffle = !_shuffle;
    // In trove mode the playlist is mpv's, so shuffling is mpv's too — it
    // reorders and re-emits the playlist, and unshuffling restores the original
    // folder order.
    if (_trove) {
      _player.setShuffle(_shuffle).catchError((_) {});
    }
    notifyListeners();
  }

  void cycleRepeat() {
    _repeat = MusicRepeat.values[(_repeat.index + 1) % MusicRepeat.values.length];
    _applyRepeat();
    notifyListeners();
  }

  /// Push the repeat setting to the player. Only meaningful for the trove
  /// playlist; the asset soundtrack is a single media at a time whose advance is
  /// decided in _onComplete, so mpv is told to do nothing there.
  Future<void> _applyRepeat() async {
    final mode = !_trove
        ? PlaylistMode.none
        : switch (_repeat) {
            MusicRepeat.off => PlaylistMode.none,
            MusicRepeat.all => PlaylistMode.loop,
            MusicRepeat.one => PlaylistMode.single,
          };
    try {
      await _player.setPlaylistMode(mode);
    } catch (_) {}
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

  Future<void> next() async {
    if (_trove) {
      try {
        await _player.next();
      } catch (_) {}
      return;
    }
    if (_tracks.isEmpty) return;
    return playIndex(_pickNext());
  }

  Future<void> prev() async {
    if (_pos.inSeconds > 3) return seek(Duration.zero);
    if (_trove) {
      try {
        await _player.previous();
      } catch (_) {}
      return;
    }
    if (_tracks.isEmpty) return;
    return playIndex(_shuffle && _tracks.length > 1 ? _pickNext() : _index - 1);
  }

  // A track ended on its own. In trove mode mpv advances the playlist itself, so
  // the only thing left to handle is the END of the folder — rest there, never
  // fall through to the easter-egg soundtrack. For the asset soundtrack, honour
  // repeat/shuffle: explicit repeat-one wins (a user can still lock one track);
  // otherwise Nostalgia's egg shuffle keeps it endlessly non-linear, never
  // repeating back-to-back.
  void _onComplete() {
    if (_trove) {
      final pl = _plist;
      final last = pl == null || pl.index >= pl.medias.length - 1;
      // Mid-playlist completions are mpv advancing; only the final one rests.
      if (last && _repeat == MusicRepeat.off) stopPlayback();
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
    _analysisToken++;
    _closeAnalysis(); // close the visualizer handle, drop any temp
    _nostalgiaStop?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
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
