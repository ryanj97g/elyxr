// The visual language of elyxr, from DESIGN.md: a tinted metal chassis with a
// phosphor CRT tube. Five accents, each casting the metal a different way; the
// phosphor colours are computed from the accent so a new colour needs no new
// constants. This file is the single source of those tokens.

import 'package:flutter/painting.dart';

/// Parse `#rrggbb` into a fully opaque [Color].
Color _hex(String h) {
  final v = int.parse(h.substring(1), radix: 16);
  return Color(0xFF000000 | v);
}

/// The three typefaces, one job each (DESIGN.md · Type).
class Fonts {
  /// Chassis labels, section headers, rail buttons.
  static const chassis = 'Chakra Petch';

  /// Everything on the glass — file rows, readouts, settings.
  static const glass = 'VT323';

  /// The ticker, and version strings. Nothing else.
  static const mono = 'IBM Plex Mono';
}

/// The five switchable accents.
enum Accent { mono, cyan, amber, green, violet }

/// The three list densities (row padding + font size only).
enum Density { tight, mid, roomy }

extension AccentLabel on Accent {
  String get label => switch (this) {
        Accent.mono => 'MONO',
        Accent.cyan => 'CYAN',
        Accent.amber => 'AMBER',
        Accent.green => 'GREEN',
        Accent.violet => 'VIOLET',
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

  double get font => switch (this) {
        Density.tight => 15.5,
        Density.mid => 16.5,
        Density.roomy => 18,
      };
}

/// The fixed per-accent data: the accent colour, the ink that sits on it, and
/// the nine tinted metal shades. Everything else is computed.
class AccentSpec {
  final Color a; // accent
  final Color ink; // text sitting on the accent
  // Metal, in order: chassis top / mid / bottom, border, highlight,
  // muted text, bright text, recess, vent stripe.
  final Color m1, m2, m3, mb, mh, mt, ml, mv1, mv2;

  const AccentSpec._(this.a, this.ink, this.m1, this.m2, this.m3, this.mb,
      this.mh, this.mt, this.ml, this.mv1, this.mv2);

  static AccentSpec of(Accent accent) => _specs[accent]!;
}

final Map<Accent, AccentSpec> _specs = {
  Accent.mono: AccentSpec._(_hex('#c9ced6'), _hex('#0d0f12'), _hex('#3a3d40'),
      _hex('#26282b'), _hex('#202225'), _hex('#4a4e52'), _hex('#5d6165'),
      _hex('#82868a'), _hex('#d4d8dc'), _hex('#16181a'), _hex('#2e3134')),
  Accent.cyan: AccentSpec._(_hex('#4cc2d6'), _hex('#04131a'), _hex('#303a3d'),
      _hex('#1f2729'), _hex('#1a2123'), _hex('#3f4c50'), _hex('#525f63'),
      _hex('#77848a'), _hex('#c8d6da'), _hex('#131b1d'), _hex('#283336')),
  Accent.amber: AccentSpec._(_hex('#f5b942'), _hex('#1a1204'), _hex('#3b3830'),
      _hex('#27241d'), _hex('#201e18'), _hex('#4d4940'), _hex('#605b50'),
      _hex('#847e70'), _hex('#d9d3c4'), _hex('#191712'), _hex('#332f27')),
  Accent.green: AccentSpec._(_hex('#5fd18a'), _hex('#04120a'), _hex('#333b36'),
      _hex('#212823'), _hex('#1b211d'), _hex('#434d46'), _hex('#565f58'),
      _hex('#787e7a'), _hex('#cfd9d2'), _hex('#151a17'), _hex('#2b332d')),
  Accent.violet: AccentSpec._(_hex('#b98ae8'), _hex('#120a1a'), _hex('#35323a'),
      _hex('#232128'), _hex('#1d1b22'), _hex('#474350'), _hex('#5a5566'),
      _hex('#7e7887'), _hex('#d4cfda'), _hex('#17151a'), _hex('#2f2c35')),
};

Color _mix(Color c, double amt) => Color.fromARGB(
      255,
      (c.r * 255 + (255 - c.r * 255) * amt).round(),
      (c.g * 255 + (255 - c.g * 255) * amt).round(),
      (c.b * 255 + (255 - c.b * 255) * amt).round(),
    );

Color _darken(Color c, double amt) => Color.fromARGB(
      255,
      (c.r * 255 * (1 - amt)).round(),
      (c.g * 255 * (1 - amt)).round(),
      (c.b * 255 * (1 - amt)).round(),
    );

/// A fully resolved palette for one (accent, dark/light) pairing: the accent,
/// the tinted metal, and the six computed phosphor roles plus the tube colour.
/// Widgets read from this and never compute colour themselves.
class Palette {
  final Accent accent;
  final bool dark;
  final AccentSpec _s;

  Palette(this.accent, this.dark) : _s = AccentSpec.of(accent);

  Color get a => _s.a;
  Color get ink => _s.ink;

  // Metal.
  Color get m1 => _s.m1;
  Color get m2 => _s.m2;
  Color get m3 => _s.m3;
  Color get mb => _s.mb;
  Color get mh => _s.mh;
  Color get mt => _s.mt;
  Color get ml => _s.ml;
  Color get mv1 => _s.mv1;
  Color get mv2 => _s.mv2;

  // Phosphor — computed from the accent (DESIGN.md · Phosphor).
  Color get bright => dark ? _mix(a, 0.55) : _hex('#0d1a12');
  Color get soft => dark ? _mix(a, 0.15) : _hex('#1d3326');
  Color get mid => dark ? _darken(a, 0.46) : _hex('#4a6b57');
  Color get dim => dark ? _darken(a, 0.78) : _hex('#c3d4c8');
  Color get foot => dark ? _darken(a, 0.66) : _hex('#7c9186');
  Color get glow => dark ? _darken(a, 0.28) : _hex('#3c5c48');

  Color get tubeBg => dark ? _hex('#040705') : _hex('#e8efe9');

  /// Accent at a given alpha fraction (for the faint bands and glows).
  Color aAlpha(double f) => a.withValues(alpha: f);
}

/// Fixed window size (DESIGN.md): portrait, not resizable in v1.
const double kAppWidth = 440;
const double kAppHeight = 884;
