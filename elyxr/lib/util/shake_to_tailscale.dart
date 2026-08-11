
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../state/settings.dart';
import 'lymnal_host.dart';
import 'platform_caps.dart';

class ShakeDetector {
  static const double jolt = 22.0;

  static const int debounceMs = 90;

  static const int joltsToFire = 4;
  static const int windowMs = 1200;

  static const int cooldownMs = 4000;

  final List<int> _hits = [];
  int? _lastHit;
  int? _firedAt;

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

double shakeMagnitude(double x, double y, double z) =>
    math.sqrt(x * x + y * y + z * z);

class ShakeToTailscale extends StatefulWidget {
  final Widget child;

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
