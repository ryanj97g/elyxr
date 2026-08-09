// The bridge to the on-device lymnal on Android. Desktop runs lymnal as a real
// OS service (systemd / a hidden Windows process); a phone can't shell out from
// Dart, so the app asks the native side (MainActivity's MethodChannel) to run a
// foreground service that execs the bundled liblymnal.so on loopback. Either
// way the app talks to its own local lymnal at 127.0.0.1:7749 — never straight
// to the remote.

import 'package:flutter/services.dart';

import 'platform_caps.dart';

class LymnalHost {
  LymnalHost._();
  static const _ch = MethodChannel('elyxr/lymnal');

  /// The app's private data dir on Android, where lymnal keeps its config,
  /// link.json and the lymbo cache. Null off Android (desktop uses $HOME).
  static Future<String?> dataDir() async {
    if (!Caps.isAndroid) return null;
    try {
      return await _ch.invokeMethod<String>('dataDir');
    } catch (_) {
      return null;
    }
  }

  /// The app's native-lib dir on Android, where the bundled binaries live
  /// (liblymnal.so, libmodrender.so, libopenmpt.so). Null off Android.
  static Future<String?> nativeLibDir() async {
    if (!Caps.isAndroid) return null;
    try {
      return await _ch.invokeMethod<String>('nativeLibDir');
    } catch (_) {
      return null;
    }
  }

  /// Start the foreground service that runs lymnal. No-op off Android.
  static Future<void> start() async {
    if (!Caps.isAndroid) return;
    try {
      await _ch.invokeMethod('start');
    } catch (_) {}
  }

  /// Stop the lymnal service (device unpaired). No-op off Android.
  static Future<void> stop() async {
    if (!Caps.isAndroid) return;
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {}
  }
}
