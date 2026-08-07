// Retro sound effects for Nostalgia Mode. Each event routes through here, gated
// on Nostalgia Mode + the Sound switch. Playback is via audioplayers; a missing
// sound file (none dropped in yet) is swallowed, so it never affects the app.
// See assets/sounds/README.md for the file names.

import 'package:audioplayers/audioplayers.dart';

import 'settings.dart';

class SoundController {
  final SettingsController settings;
  final AudioPlayer _player = AudioPlayer();

  SoundController(this.settings) {
    _player.setReleaseMode(ReleaseMode.stop);
  }

  bool get _on => settings.nostalgia && settings.sound;

  Future<void> _play(String name) async {
    if (!_on) return;
    try {
      await _player.stop();
      await _player.play(AssetSource('sounds/$name'), volume: 0.7);
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
