// Retro sound effects for Nostalgia Mode, played through audioplayers (the
// system's GStreamer on Linux). Each shot uses a fresh one-shot player so rapid
// events stack instead of cutting each other off; the player disposes itself
// when the clip finishes. A missing file or absent audio device is swallowed, so
// it never affects the app. See assets/sounds/README.md for the file names.

import 'package:audioplayers/audioplayers.dart';

import 'settings.dart';

class SoundController {
  final SettingsController settings;
  SoundController(this.settings);

  bool get _on => settings.nostalgia && settings.sound;

  /// The laugh that fires every time Nostalgia Mode is switched on. It is *not*
  /// gated by the Sound switch, and each call is its own player, so rapid toggles
  /// stack rather than cut each other off.
  Future<void> laugh() => _shoot('sounds/laugh.mp3');

  Future<void> _play(String name) {
    if (!_on) return Future<void>.value();
    return _shoot('sounds/$name');
  }

  // Fire a one-shot clip on a throwaway player, disposed when it completes.
  Future<void> _shoot(String assetPath) async {
    final p = AudioPlayer();
    try {
      p.onPlayerComplete.listen((_) => p.dispose());
      // AssetSource prepends 'assets/'; pass the path without it.
      await p.play(AssetSource(assetPath));
    } catch (_) {
      await p.dispose();
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
