// The colour engine: OKLCH → sRGB with gamut-true chroma, ported from a tuned
// theming system. The point isn't "OKLCH instead of hex" — it's that a colour is
// requested as a hue plus a chroma *budget*, and the engine hands back the
// richest colour that is still TRUE to that hue in sRGB. Ask for more chroma than
// the gamut can show and it clamps instead of letting the value gamut-map and
// drift the hue (a blue drifting to teal, a deep orange to red). That clamp is
// what lets a whole screen sit in one phosphor colour and stay one colour.
//
// Pure Dart on purpose (ARGB ints, no Flutter), so the math is testable on its
// own; tokens.dart wraps the ints in Color.

import 'dart:math' as math;

/// OKLab → linear sRGB (may be out of gamut). The standard OKLab matrix.
List<double> _linear(double l, double c, double hDeg) {
  final h = hDeg * math.pi / 180.0;
  final a = c * math.cos(h);
  final b = c * math.sin(h);
  final l_ = l + 0.3963377774 * a + 0.2158037573 * b;
  final m_ = l - 0.1055613458 * a - 0.0638541728 * b;
  final s_ = l - 0.0894841775 * a - 1.2914855480 * b;
  final ll = l_ * l_ * l_;
  final mm = m_ * m_ * m_;
  final ss = s_ * s_ * s_;
  return [
    4.0767416621 * ll - 3.3077115913 * mm + 0.2309699292 * ss,
    -1.2684380046 * ll + 2.6097574011 * mm - 0.3413193965 * ss,
    -0.0041960863 * ll - 0.7034186147 * mm + 1.7076147010 * ss,
  ];
}

/// Does this OKLCH colour fit in sRGB (every channel in [0,1], with slack)?
bool _inGamut(double l, double c, double h) {
  const e = 0.001;
  final rgb = _linear(l, c, h);
  for (final v in rgb) {
    if (v < -e || v > 1 + e) return false;
  }
  return true;
}

/// The most chroma a given lightness+hue can hold in sRGB — a 20-step binary
/// search (~20 gamut checks, cheap). This is the primitive everything leans on.
double maxChroma(double l, double h) {
  double lo = 0, hi = 0.4;
  for (var i = 0; i < 20; i++) {
    final mid = (lo + hi) / 2;
    if (_inGamut(l, mid, h)) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return lo;
}

/// linear-light channel → 8-bit sRGB (gamma companding + clamp).
int _enc(double x) {
  if (x < 0) x = 0;
  if (x > 1) x = 1;
  final s = x <= 0.0031308 ? 12.92 * x : 1.055 * math.pow(x, 1 / 2.4) - 0.055;
  return (s * 255).round().clamp(0, 255);
}

/// An OKLCH colour as opaque 0xFFRRGGBB. Chroma is used as given (no clamp) —
/// use [trueArgb] when the value must stay true to the hue.
int oklchArgb(double l, double c, double h) {
  final rgb = _linear(l, c, h);
  return 0xFF000000 | (_enc(rgb[0]) << 16) | (_enc(rgb[1]) << 8) | _enc(rgb[2]);
}

/// An OKLCH colour clamped to the richest chroma that stays true to the hue.
int trueArgb(double l, double h, double reqC) =>
    oklchArgb(l, math.min(reqC, maxChroma(l, h)), h);

/// The lightness that can hold [targetC] chroma for [h], searched from [hiL]
/// toward [loL] — the lightest such L, or the darkest when [preferDark]. This is
/// how saturation is homogenised across hues: a narrow-gamut hue (blue, teal)
/// rides to whatever lightness lets it reach the same chroma as a wide one.
double lForC(double h, double targetC, double hiL, double loL,
    {bool preferDark = false}) {
  if (preferDark) {
    for (double l = loL; l <= hiL; l += 0.01) {
      if (maxChroma(l, h) >= targetC) return l;
    }
    return hiL;
  }
  for (double l = hiL; l >= loL; l -= 0.01) {
    if (maxChroma(l, h) >= targetC) return l;
  }
  return loL;
}

/// The accent's own chroma at a saturation multiplier — the source formula:
/// a base chroma scaled by the hue's chroma-multiplier and the drag, floored so
/// it never goes flat and clamped to the hue's in-gamut ceiling.
double accentChroma(double chromaMul, double maxCeil, double sat) {
  final c = 0.13 * chromaMul * sat;
  // A lower floor gives the muting drag more room to wash a colour toward grey.
  final floored = c < 0.045 ? 0.045 : c;
  return floored < maxCeil ? floored : maxCeil;
}
