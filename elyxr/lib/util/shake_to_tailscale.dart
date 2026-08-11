// Shake the phone to jump to Tailscale.
//
// Not the same mechanism as shake-to-close on desktop, which watches the OS
// window being whipped around with the mouse (see shake_to_close.dart). There's
// no window on a phone, so this reads the accelerometer.
//
// Off by default and switched on in Settings, because a gesture that launches
// another app is disruptive in a way that a gesture that closes one isn't: a
// phone gets shaken in pockets, in cars, walking. The app also offers Tailscale
// as a button the moment it detects the tailnet is down (see _OfflineNotice) —
// this gesture is for the other case, where the connection is broken and the app
// hasn't worked that out yet.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../state/settings.dart';
import 'lymnal_host.dart';
import 'platform_caps.dart';

/// Decides whether a stream of accelerometer magnitudes is someone shaking the
/// phone on purpose. Pure and clock-injected so the thresholds can be tested
/// rather than guessed at on a device.
///
/// The bar is deliberately high, in the same spirit as the desktop shake: several
/// distinct jolts inside a short window, then a cooldown so one long shake fires
/// once instead of repeatedly.
class ShakeDetector {
  /// Total acceleration, in m/s², above which a sample counts as a jolt.
  /// Gravity alone is ~9.8 and brisk walking peaks near 13–15, so this sits well
  /// clear of both.
  static const double jolt = 22.0;

  /// Jolts closer together than this are the same one.
  static const int debounceMs = 90;

  /// How many jolts, inside [windowMs], make a shake.
  static const int joltsToFire = 4;
  static const int windowMs = 1200;

  /// After firing, ignore everything for this long — a shake doesn't stop the
  /// instant it has been recognised.
  static const int cooldownMs = 4000;

  final List<int> _hits = [];
  // Null until each has actually happened. NOT zero: "last fired at 0" reads as
  // a real time, so with small timestamps the cooldown swallows the first four
  // seconds of input. Live it would never show, because a wall-clock millisecond
  // count is enormous and the subtraction always clears the bar.
  int? _lastHit;
  int? _firedAt;

  /// Feed one sample. Returns true on the sample that completes a shake.
  bool feed(double magnitude, int atMs) {
    final firedAt = _firedAt;
    if (firedAt != null && atMs - firedAt < cooldownMs) return false;
    if (magnitude < jolt) return false;
    final lastHit = _lastHit;
    if (lastHit != null && atMs - lastHit < debounceMs) return false;
    _lastHit = atMs;
    _hits.add(atMs);
    _hits.removeWhere((t) => atMs - t > windowMs);
    if (_hits.length < joltsToFire) return false;
    _hits.clear();
    _firedAt = atMs;
    return true;
  }
}

/// Magnitude of one accelerometer reading, gravity included.
double shakeMagnitude(double x, double y, double z) =>
    math.sqrt(x * x + y * y + z * z);

class ShakeToTailscale extends StatefulWidget {
  final Widget child;

  /// What a recognised shake does. Injectable so the wiring can be tested
  /// without a device or a real Tailscale install.
  final Future<void> Function()? onShake;

  const ShakeToTailscale({super.key, required this.child, this.onShake});

  @override
  State<ShakeToTailscale> createState() => _ShakeToTailscaleState();
}

class _ShakeToTailscaleState extends State<ShakeToTailscale> {
  StreamSubscription<AccelerometerEvent>? _sub;
  final _detector = ShakeDetector();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Follows the setting: turning it off drops the subscription, so a phone with
    // the gesture disabled isn't running the accelerometer for nothing.
    final on = context.watch<SettingsController>().shakeForTailscale;
    if (on && Caps.isAndroid) {
      _listen();
    } else {
      _stop();
    }
  }

  void _listen() {
    if (_sub != null) return;
    try {
      _sub = accelerometerEventStream(
        samplingPeriod: SensorInterval.gameInterval,
      ).listen(_onSample, onError: (_) => _stop());
    } catch (_) {
      // No accelerometer, or the platform refused it. The button in the offline
      // notice still covers the case the app can detect.
    }
  }

  void _stop() {
    _sub?.cancel();
    _sub = null;
  }

  void _onSample(AccelerometerEvent e) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!_detector.feed(shakeMagnitude(e.x, e.y, e.z), now)) return;
    (widget.onShake ?? LymnalHost.openTailscale)();
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
