// The Nostalgia Mode music player: a playlist of whatever's in assets/music/,
// with play/pause, seek, and skip — driven by audioplayers. Track names are the
// filenames, tidied. All playback is guarded so a missing file or absent audio
// device never affects the app.

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;

class MusicController extends ChangeNotifier {
  final AudioPlayer _player = AudioPlayer();

  List<String> _tracks = []; // asset paths under assets/music/
  int _index = 0;
  bool _playing = false;
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
    _player.onPlayerComplete.listen((_) => next());
    _load();
  }

  List<String> get tracks => _tracks;
  bool get hasTracks => _tracks.isNotEmpty;
  int get index => _index;
  int get count => _tracks.length;
  bool get playing => _playing;
  Duration get position => _pos;
  Duration get duration => _dur;
  String get title => hasTracks ? _pretty(_tracks[_index]) : 'no tracks';

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

  Future<void> next() => playIndex(_index + 1);
  Future<void> prev() => playIndex(_index - 1);

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
