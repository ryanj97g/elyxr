// Turning a window of samples into an oscilloscope trace.
//
// Kept apart from the controller, and pure, because the two things that decide
// whether a scope looks like an instrument or like noise are both arithmetic, and
// both are invisible until you're staring at the finished thing:
//
//  - TRIGGERING. A real scope waits for the signal to cross zero going upward
//    before it starts drawing. Without that, each frame starts at an arbitrary
//    point in the waveform and the whole trace slides left and right at random —
//    it reads as jitter, not as signal. The trace is mirrored about its centre,
//    which makes this worse rather than better: a symmetrical shape gives the eye
//    a fixed spine to notice the sliding against.
//
//  - GAIN. A raw waveform is honest in a way spectrum bars aren't. Each of those
//    bars is scaled on its own, so they always look alive; a waveform during a
//    quiet intro is a nearly flat line. So the trace is normalised against a
//    rolling peak — loud passages fill the band, quiet ones still move, and real
//    silence is genuinely flat rather than amplified dither.

import 'dart:math' as math;
import 'dart:typed_data';

/// How many points the trace is drawn from.
const int kScopePoints = 128;

/// Samples the trace spans: four per point, so each point is a small mean and the
/// line comes out wave-like instead of picking one sample in five out of the
/// stream and looking like noise.
///
/// At 44.1kHz this is ~11.6ms of audio — a couple of cycles of a bass note, a
/// dozen of a vocal. Enough to read as a waveform, not so much that it packs into
/// a solid block.
const int kScopeSpan = kScopePoints * 4;

/// Rolling peak below which the trace shrinks toward flat instead of being
/// amplified to fill the band. Without a floor, normalising against the peak
/// turns the noise in a silent passage into a full-height mess.
const double _floor = 0.04;

/// How much of the band the loudest part of the trace fills.
const double _fill = 0.92;

/// Per-frame decay of the rolling peak — a slow release so the trace doesn't
/// pump. At one call per displayed frame this is a half-life near a second.
const double _release = 0.99;

/// Where the trigger arms, as a fraction of the rolling peak. The signal has to
/// go below this before an upward zero crossing counts, so a trace doesn't fire
/// on the first sample that happens to sit near zero.
const double _armAt = 0.05;

/// A trace plus the rolling peak it leaves behind — the caller holds the peak
/// between frames and hands it back, so this stays a pure function of its inputs.
class ScopeTrace {
  /// [kScopePoints] values in -1..1. All zero when there's nothing to show.
  final List<double> points;
  final double peak;
  const ScopeTrace(this.points, this.peak);
}

/// [mono] samples at the play head (-1..1, longer than [kScopeSpan] so there's
/// room to hunt for a trigger) → the trace to draw, and the updated rolling peak.
ScopeTrace scopeTrace(Float64List mono, double lastPeak) {
  var framePeak = 0.0;
  for (final v in mono) {
    final m = v.abs();
    if (m > framePeak) framePeak = m;
  }
  final peak = math.max(framePeak, lastPeak * _release);
  final out = List<double>.filled(kScopePoints, 0.0);
  // Genuinely nothing in this window: a flat line, and the peak keeps decaying so
  // the trace comes back up smoothly rather than snapping when audio returns.
  if (framePeak <= 0) return ScopeTrace(out, peak);

  final start = _triggerAt(mono, peak);
  // Normalise to the rolling peak, then fade the whole trace out as that peak
  // falls under the floor — so quiet is small, silence is flat, and neither is
  // the same as loud.
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

/// The index to start drawing from: the first upward zero crossing that the
/// signal has properly dipped below zero before reaching. Falls back to the start
/// of the window when there isn't one in reach — true of a note lower than about
/// 86Hz, where one period is longer than the room we have to look in.
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
