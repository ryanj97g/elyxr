
import 'dart:math' as math;
import 'dart:typed_data';

const int kScopePoints = 128;

const int kScopeSpan = kScopePoints * 4;

const double _floor = 0.04;

const double _fill = 0.92;

const double _release = 0.99;

const double _armAt = 0.05;

class ScopeTrace {
  final List<double> points;
  final double peak;
  const ScopeTrace(this.points, this.peak);
}

ScopeTrace scopeTrace(Float64List mono, double lastPeak) {
  var framePeak = 0.0;
  for (final v in mono) {
    final m = v.abs();
    if (m > framePeak) framePeak = m;
  }
  final peak = math.max(framePeak, lastPeak * _release);
  final out = List<double>.filled(kScopePoints, 0.0);
  if (framePeak <= 0) return ScopeTrace(out, peak);

  final start = _triggerAt(mono, peak);
  final gain = _fill / math.max(peak, _floor);
  final envelope = (peak / _floor).clamp(0.0, 1.0);
  const bin = kScopeSpan ~/ kScopePoints;
  for (var i = 0; i < kScopePoints; i++) {
    var sum = 0.0;
    for (var k = 0; k < bin; k++) {
      sum += mono[start + i * bin + k];
    }
    out[i] = ((sum / bin) * gain * envelope).clamp(-1.0, 1.0);
  }
  return ScopeTrace(out, peak);
}

int _triggerAt(Float64List mono, double peak) {
  final limit = mono.length - kScopeSpan;
  if (limit <= 0) return 0;
  final arm = -_armAt * peak;
  var armed = false;
  for (var i = 0; i <= limit; i++) {
    final v = mono[i];
    if (!armed) {
      if (v < arm) armed = true;
    } else if (v >= 0) {
      return i;
    }
  }
  return 0;
}
