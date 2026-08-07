// Pins the OKLCH engine to the tuned source math. The expected values are the
// oracle from the reference implementation (same matrix + sRGB gamma); a ±2/255
// tolerance absorbs rounding-mode differences without hiding a real drift.

import 'package:flutter_test/flutter_test.dart';
import 'package:elyxr/design/oklch.dart';

void _expectArgb(int got, int want, {int tol = 2}) {
  int ch(int v, int shift) => (v >> shift) & 0xFF;
  for (final shift in [16, 8, 0]) {
    final d = (ch(got, shift) - ch(want, shift)).abs();
    expect(d <= tol, isTrue,
        reason: 'channel@$shift off by $d — got '
            '${got.toRadixString(16)} want ${want.toRadixString(16)}');
  }
}

void main() {
  test('accent chroma formula (base 0.13, floored 0.075, clamped to ceiling)', () {
    expect(accentChroma(1.00, 0.22, 1.0), closeTo(0.1300, 1e-9));
    expect(accentChroma(0.95, 0.17, 1.0), closeTo(0.1235, 1e-9));
    expect(accentChroma(1.00, 0.19, 0.4), closeTo(0.0750, 1e-9)); // floor
    expect(accentChroma(1.00, 0.15, 2.6), closeTo(0.1500, 1e-9)); // ceiling
  });

  test('swatch colours match the oracle', () {
    _expectArgb(oklchArgb(0.56, 0.1300, 145), 0xFF3B8841); // green
    _expectArgb(oklchArgb(0.70, 0.1300, 82), 0xFFC6952C);  // amber
    _expectArgb(oklchArgb(0.70, 0.1235, 352), 0xFFD87DA6); // pink
  });

  test('gamut-true (clamped) phosphor colours match', () {
    _expectArgb(trueArgb(0.88, 145, 0.198), 0xFF77F980); // green bright
    _expectArgb(trueArgb(0.66, 145, 0.220), 0xFF00B12F); // green mid
    _expectArgb(trueArgb(0.24, 145, 0.012), 0xFF1C211C); // metal whisper
  });

  test('maxChroma clamps a request that would leave the gamut', () {
    // A wildly over-budget request must not exceed what the hue can hold.
    expect(maxChroma(0.66, 145), lessThan(0.30));
    _expectArgb(trueArgb(0.66, 145, 1.0), trueArgb(0.66, 145, maxChroma(0.66, 145)));
  });
}
