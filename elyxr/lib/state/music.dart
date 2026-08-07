// The Nostalgia Mode music player: a playlist of whatever's in assets/music/,
// with play/pause, seek, and skip — driven by audioplayers. Track names are the
// filenames, tidied. All playback is guarded so a missing file or absent audio
// device never affects the app.

import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;

/// Loop nothing, the whole list, or the one track.
enum MusicRepeat { off, all, one }

class MusicController extends ChangeNotifier {
  final AudioPlayer _player = AudioPlayer();
  final _rnd = math.Random();

  List<String> _tracks = []; // asset paths under assets/music/
  int _index = 0;
  bool _playing = false;
  bool _shuffle = false;
  MusicRepeat _repeat = MusicRepeat.off;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;

  MusicController() {
    _player.onPositionChanged.listen((p) {
      _pos = p;
      notifyListeners();
    });
    _player.onDurationChanged.listen((d) {
      _dur = d;
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
  String get title => hasTracks ? _pretty(_tracks[_index]) : 'no tracks';
  String titleAt(int i) => _pretty(_tracks[i]);
  // A track is "active" (worth showing the mini-player for) once one is playing
  // or paused mid-track.
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

  // audioplayers' AssetSource path is relative to assets/, so drop the prefix.
  String _src(String asset) => asset.replaceFirst('assets/', '');

  Future<void> playIndex(int i) async {
    if (_tracks.isEmpty) return;
    _index = i % _tracks.length;
    if (_index < 0) _index += _tracks.length;
    _pos = Duration.zero;
    try {
      await _player.stop();
      await _player.play(AssetSource(_src(_tracks[_index])), volume: 0.9);
      _playing = true;
    } catch (_) {
      _playing = false;
    }
    notifyListeners();
  }

  Future<void> toggle() async {
    if (_tracks.isEmpty) return;
    try {
      if (_playing) {
        await _player.pause();
        _playing = false;
      } else if (_dur > Duration.zero) {
        await _player.resume();
        _playing = true;
      } else {
        await playIndex(_index);
        return;
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

  // Manual skip: always advances (or wraps).
  Future<void> next() =>
      _tracks.isEmpty ? Future<void>.value() : playIndex(_pickNext());

  // Manual previous: restart the current track if we're a few seconds in
  // (the usual player behaviour), otherwise step back.
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
