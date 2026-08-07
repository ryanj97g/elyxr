// Retro sound effects for Nostalgia Mode. The whole system is here and wired —
// every event routes through it, gated on Nostalgia Mode + the Sound switch —
// but actual playback is deliberately left as a one-step local activation,
// because a native audio plugin can't be validated in this project's headless
// Windows CI, and audioplayers_linux pulls in GStreamer at build time (which,
// if missing, would break the *Linux* build the CI never runs). Until then every
// method is a safe no-op, so the wiring can ship without any risk to the build
// or the updater.
//
// TO MAKE IT AUDIBLE (do this on a machine where you can run the build):
//   1. add `audioplayers: ^6.1.0` under dependencies in pubspec.yaml
//   2. in elyxr.sh's app build deps, add:
//        libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev
//   3. drop the <name>.wav files listed in assets/sounds/README.md into that dir
//   4. give this class `final AudioPlayer _player = AudioPlayer();` and replace
//      the body of [_play] with:
//        if (!_on) return;
//        try { _player.stop(); _player.play(AssetSource('sounds/$name')); }
//        catch (_) {}
// That's the whole activation — everything below already calls the right sound
// at the right moment.

import 'settings.dart';

class SoundController {
  final SettingsController settings;
  SoundController(this.settings);

  bool get _on => settings.nostalgia && settings.sound;

  // No-op until a player is wired (see header). Kept side-effect-free so it can
  // never break a build or a device.
  void _play(String name) {
    if (!_on) return;
    // (audioplayers call goes here — see the file header.)
  }

  // The events, each mapped to its sound file. Call sites live at the natural
  // moment each thing happens.
  void connected() => _play('connect.wav');
  void uploadDone() => _play('upload.wav');
  void downloadDone() => _play('download.wav');
  void deleted() => _play('delete.wav');
  void pairing() => _play('pair.wav');
  void toggle(bool on) => _play(on ? 'on.wav' : 'off.wav');
  void hover() => _play('hover.wav');
}
