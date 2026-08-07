// The Nostalgia Mode music player, on the SoLoud engine. A playlist of whatever
// is in assets/music/ (.ogg/.mp3/.wav), with play/pause, seek, skip, shuffle and
// repeat. Position is polled (SoLoud has no position stream); a track ending is
// detected by its voice handle going invalid. All playback is guarded so a
// missing file or absent audio device never affects the app.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:flutter_soloud/flutter_soloud.dart';

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
  String get title => hasTracks ? _pretty(_tracks[_index]) : 'no tracks';
  String titleAt(int i) => _pretty(_tracks[i]);
  bool get active => hasTracks && (_playing || _pos > Duration.zero);

  Future<void> _load() async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      _tracks = manifest
          .listAssets()
          .where((a) =>
              a.startsWith('assets/music/') &&
              (a.endsWith('.ogg') || a.endsWith('.mp3') || a.endsWith('.wav')))
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
    _pos = Duration.zero;
    try {
      if (_handle != null) await _sl.stop(_handle!);
      _source = await _sl.loadAsset(_tracks[_index]);
      _dur = _sl.getLength(_source!);
      _handle = _sl.play(_source!, volume: 0.9);
      _playing = true;
      _startPoll();
    } catch (_) {
      _playing = false;
    }
    notifyListeners();
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
