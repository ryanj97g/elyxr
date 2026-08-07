// The visual language of elyxr: a tinted metal chassis with a phosphor CRT tube.
// Named phosphor accents, each just a hue + chroma budget; every colour — the
// glowing tube in dark, the paper terminal in light, and the metal — is derived
// from that hue by the OKLCH engine (oklch.dart), gamut-true so a whole screen
// sits in one phosphor colour and stays that colour. A new accent is one row.

import 'package:flutter/painting.dart';

import 'oklch.dart';

Color _c(int argb) => Color(argb);

/// The three typefaces, one job each (DESIGN.md · Type).
class Fonts {
  /// Chassis labels, section headers, rail buttons.
  static const chassis = 'Chakra Petch';

  /// Everything on the glass — file rows, readouts, settings.
  static const glass = 'VT323';

  /// The ticker, and version strings. Nothing else.
  static const mono = 'IBM Plex Mono';
}

/// The switchable phosphor accents, in spectrum order. `mono` is the white
/// phosphor (its intensity is a lightness, not a saturation).
enum Accent { red, amber, green, cyan, blue, purple, pink, mono }

/// The three list densities (row padding + font size only).
enum Density { tight, mid, roomy }

extension AccentLabel on Accent {
  String get label => switch (this) {
        Accent.red => 'RED',
        Accent.amber => 'AMBER',
        Accent.green => 'GREEN',
        Accent.cyan => 'CYAN',
        Accent.blue => 'BLUE',
        Accent.purple => 'PURPLE',
        Accent.pink => 'PINK',
        Accent.mono => 'MONO',
      };
}

extension DensityLabel on Density {
  String get label => switch (this) {
        Density.tight => 'TIGHT',
        Density.mid => 'MID',
        Density.roomy => 'ROOMY',
      };

  double get pad => switch (this) {
        Density.tight => 6,
        Density.mid => 10,
        Density.roomy => 15,
      };

  /// The base glass font. Density's size change is applied globally through the
  /// tube's text scaler (see [scale]) so every readout scales together, not just
  /// file rows — this stays a single base size.
  double get font => 16.5;

  /// The global text scale for everything on the glass. The metal chassis is
  /// unaffected — physical controls keep their fixed size. Containers that hold
  /// scalable text grow with it; fixed slots ellipsis or fit rather than clip.
  double get scale => switch (this) {
        Density.tight => 0.9,
        Density.mid => 1.0,
        Density.roomy => 1.15,
      };
}

/// One accent as a hue and a chroma budget — no baked colours. `mono` is
/// achromatic; its `baseL` is the default lightness of the white phosphor.
class AccentSpec {
  final double hue;
  final double chromaMul;
  final double maxCeil;
  final double baseL;
  final bool mono;
  const AccentSpec(this.hue, this.chromaMul, this.maxCeil, this.baseL,
      {this.mono = false});

  static AccentSpec of(Accent a) => _specs[a]!;
}

// First-guess hues, seeded from a tuned source palette. baseL is the accent
// swatch's lightness; chromaMul + maxCeil set how far the hue saturates.
final Map<Accent, AccentSpec> _specs = {
  Accent.red: const AccentSpec(18, 1.00, 0.200, 0.56),
  Accent.amber: const AccentSpec(82, 1.00, 0.190, 0.70),
  Accent.green: const AccentSpec(145, 1.00, 0.220, 0.56),
  Accent.cyan: const AccentSpec(195, 0.95, 0.150, 0.62),
  Accent.blue: const AccentSpec(255, 1.00, 0.190, 0.56),
  Accent.purple: const AccentSpec(307, 1.10, 0.235, 0.58),
  Accent.pink: const AccentSpec(352, 0.95, 0.170, 0.70),
  Accent.mono: const AccentSpec(0, 0, 0, 0.72, mono: true),
};

/// A fully resolved palette for one (accent, light/dark) pairing, plus the two
/// drag axes: `sat` (0.4–2.6) pushes a colour accent's saturation *and* glow;
/// `monoL` (0.12–0.99) sets the white phosphor's lightness. Every colour is
/// computed once here; widgets read and never compute colour themselves.
class Palette {
  final Accent accent;
  final bool dark;
  final double sat;
  final double monoL;
  final AccentSpec _s;

  Palette(this.accent, this.dark, {this.sat = 1.0, double? monoL})
      : _s = AccentSpec.of(accent),
        monoL = monoL ?? AccentSpec.of(accent).baseL {
    _build();
  }

  // ---- accent ----
  late final Color a;
  late final Color ink;

  // ---- metal (neutral, a whisper of the hue; same in light and dark) ----
  late final Color m1, m2, m3, mb, mh, mt, ml, mv1, mv2;

  // ---- phosphor / tube (hue-driven, both modes) ----
  late final Color bright, soft, mid, dim, foot, glow, tubeBg;

  void _build() {
    final h = _s.mono ? 0.0 : _s.hue;
    final maxC = _s.maxCeil;
    // The accent swatch itself.
    if (_s.mono) {
      a = _c(oklchArgb(monoL, 0, 0));
    } else {
      a = _c(oklchArgb(_s.baseL, accentChroma(_s.chromaMul, maxC, sat), h));
    }
    // Text that sits on the accent fill: dark ink on a light accent, else white.
    final accL = _s.mono ? monoL : _s.baseL;
    ink = accL > 0.70 ? _c(oklchArgb(0.24, 0, 0)) : const Color(0xFFFFFFFF);

    // Metal: a neutral chassis with only a whisper of the hue (mono = pure grey).
    final mc = _s.mono ? 0.0 : 1.0; // whisper on/off
    m1 = _c(trueArgb(0.240, h, 0.012 * mc));
    m2 = _c(trueArgb(0.160, h, 0.010 * mc));
    m3 = _c(trueArgb(0.130, h, 0.010 * mc));
    mb = _c(trueArgb(0.300, h, 0.014 * mc));
    mh = _c(trueArgb(0.400, h, 0.016 * mc));
    mt = _c(trueArgb(0.550, h, 0.010 * mc));
    ml = _c(trueArgb(0.860, h, 0.008 * mc));
    mv1 = _c(trueArgb(0.100, h, 0.008 * mc));
    mv2 = _c(trueArgb(0.210, h, 0.012 * mc));

    // Phosphor. Dark = a glowing tube (light text on near-black); light = a
    // paper terminal (dark ink on paper). The glow grows with saturation.
    final wc = _s.mono ? 0.0 : 1.0; // hue chroma on/off for the tube
    if (dark) {
      final glowBoost = sat < 1.5 ? sat : 1.5;
      bright = _s.mono
          ? _c(oklchArgb(0.90, 0, 0))
          : _c(trueArgb(0.88, h, maxC * 0.9 * glowBoost));
      soft = _c(trueArgb(0.34, h, maxC * 0.55 * wc));
      mid = _c(trueArgb(0.66, h, maxC * wc));
      dim = _c(trueArgb(0.44, h, maxC * 0.85 * wc));
      foot = _c(trueArgb(0.52, h, maxC * 0.70 * wc));
      glow = _c(trueArgb(0.60, h, maxC * wc));
      tubeBg = _c(trueArgb(0.085, h, 0.020 * wc));
    } else {
      bright = _s.mono
          ? _c(oklchArgb(0.24, 0, 0))
          : _c(trueArgb(0.28, h, maxC * wc));
      soft = _c(trueArgb(0.42, h, maxC * 0.80 * wc));
      mid = _c(trueArgb(0.50, h, maxC * 0.80 * wc));
      dim = _c(trueArgb(0.80, h, maxC * 0.40 * wc));
      foot = _c(trueArgb(0.62, h, maxC * 0.60 * wc));
      glow = _c(trueArgb(0.55, h, maxC * wc));
      tubeBg = _c(trueArgb(0.940, h, 0.018 * wc));
    }
  }

  /// Accent at a given alpha fraction (for the faint bands and glows).
  Color aAlpha(double f) => a.withValues(alpha: f);
}

/// Fixed window size (DESIGN.md): portrait, not resizable in v1.
const double kAppWidth = 440;
const double kAppHeight = 884;
