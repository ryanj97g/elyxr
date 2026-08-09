// One place that answers "what can this platform do", so feature code branches
// on a capability instead of scattering `Platform.is*` checks. Desktop
// (Linux/Windows/macOS) is the full-power case; Android is the mobile case that
// lacks a managed window, can't shell out to executables, addresses files
// through SAF rather than free paths, and — for now — has no co-located lymnal
// proxy.

import 'dart:io' show Platform;

class Caps {
  Caps._();

  static bool get isAndroid => Platform.isAndroid;
  static bool get isIOS => Platform.isIOS;
  static bool get isMobile => Platform.isAndroid || Platform.isIOS;
  static bool get isDesktop =>
      Platform.isLinux || Platform.isWindows || Platform.isMacOS;

  /// A managed desktop window via window_manager: frameless sizing, drag-to-move,
  /// the minimize/close screws, shake-to-close, the resize toggle. Desktop only —
  /// on a phone the app is simply full-screen.
  static bool get hasWindowManager => isDesktop;

  /// Can shell out to system executables with Process.run/start — service
  /// control, the updater, the gate mount, ffmpeg/openmpt, open-in-default-app.
  /// Not available on Android.
  static bool get canExec => isDesktop;

  /// Files are addressed by real, walkable filesystem paths (desktop) rather than
  /// Android's scoped-storage content URIs (SAF).
  static bool get freeFilesystem => isDesktop;

  /// A co-located lymnal proxy on loopback (127.0.0.1:7749) that the app and the
  /// gate talk to. True on desktop today; Android will host its own later.
  static bool get hasLocalLymnal => isDesktop;
}
