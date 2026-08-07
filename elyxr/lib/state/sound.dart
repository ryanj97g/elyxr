// Retro sound effects for Nostalgia Mode, played through the SoLoud engine
// (initialised in main). Each event routes through here, gated on Nostalgia
// Mode + the Sound switch. Sources are loaded once and cached; a missing file
// (none dropped in yet) is swallowed, so it never affects the app. See
// assets/sounds/README.md for the file names.

import 'package:flutter_soloud/flutter_soloud.dart';

import 'settings.dart';

class SoundController {
  final SettingsController settings;
  final Map<String, AudioSource> _cache = {};
  AudioSource? _laugh;

  SoundController(this.settings);

  bool get _on => settings.nostalgia && settings.sound;

  /// The laugh that fires every time Nostalgia Mode is switched on. It is *not*
  /// part of the gated sound-effects set — it plays regardless of the Sound
  /// switch — and each call starts a new voice, so rapid toggles stack rather
  /// than cut each other off.
  Future<void> laugh() async {
    final soloud = SoLoud.instance;
    if (!soloud.isInitialized) return;
    try {
      _laugh ??= await soloud.loadAsset('assets/sounds/laugh.mp3');
      soloud.play(_laugh!, volume: 0.9);
    } catch (_) {}
  }

  Future<void> _play(String name) async {
    if (!_on) return;
    final soloud = SoLoud.instance;
    if (!soloud.isInitialized) return;
    try {
      final src = _cache[name] ??= await soloud.loadAsset('assets/sounds/$name');
      soloud.play(src, volume: 0.7);
    } catch (_) {
      // No file yet, or no audio device — never let a chirp affect anything.
    }
  }

  void connected() => _play('connect.wav');
  void uploadDone() => _play('upload.wav');
  void downloadDone() => _play('download.wav');
  void deleted() => _play('delete.wav');
  void pairing() => _play('pair.wav');
  void toggle(bool on) => _play(on ? 'on.wav' : 'off.wav');
  void hover() => _play('hover.wav');
}
