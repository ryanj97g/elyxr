// The visual language of elyxr: a tinted metal chassis with a phosphor CRT tube.
// Named phosphor accents, each just a hue + chroma budget; every colour — the
// glowing tube in dark, the paper terminal in light, and the metal — is derived
// from that hue by the OKLCH engine (oklch.dart), gamut-true so a whole screen
// sits in one phosphor colour and stays that colour. A new accent is one row.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart' show AssetManifest, FontLoader, rootBundle;

import 'oklch.dart';

Color _c(int argb) => Color(argb);

/// The three typefaces, one job each (DESIGN.md · Type). These are mutable so
/// the terminal face can be swapped from Settings — every call site reads
/// through the `glass`/`chassis`/`mono` helpers, so changing the family here
/// re-skins the whole app on the next rebuild.
class Fonts {
  /// Chassis labels, section headers, rail buttons.
  static String chassis = 'Chakra Petch';

  /// Everything on the glass — file rows, readouts, settings. Swappable.
  static String glass = 'VT323';

  /// The ticker, and version strings. Nothing else.
  static String mono = 'IBM Plex Mono';
}

/// One selectable terminal face: the font family (must be declared in
/// pubspec.yaml under `fonts:`) and the name shown in the picker. To add one of
/// your own TTFs: drop it in assets/fonts/, add a `- family: … / - asset: …`
/// block to pubspec.yaml, then add one row here. That's the whole job.
class TermFace {
  final String family;
  final String label;
  const TermFace(this.family, this.label);
}

/// The terminal faces offered in Settings › TYPEFACE. VT323 is the default
/// phosphor face; the other two bundled families are here so the switch is live
/// immediately. Custom faces slot in as extra rows.
const List<TermFace> kTermFaces = [
  TermFace('VT323', 'VT323'),
  TermFace('Chakra Petch', 'CHAKRA'),
  TermFace('IBM Plex Mono', 'PLEX'),
  TermFace('Orbitron', 'ORBITRON'),
  TermFace('Silkscreen', 'SILKSCREEN'),
  TermFace('Julius Sans One', 'JULIUS'),
  TermFace('Redacted Script', 'REDACTED'),
  TermFace('Flow Circular', 'FLOW'),
  TermFace('Ordinary Love', 'ORDINARY'),
  TermFace('Holo Edge Four', 'HOLO EDGE'),
  TermFace('Digital Moneter', 'DIGITAL'),
];

/// Fonts the dev drops into assets/fonts/custom/ (a tracked folder, like the
/// music). Empty until loadCustomFonts() fills it once at startup.
final List<TermFace> customTermFaces = [];

/// Every selectable terminal face: the built-ins, then any custom fonts found in
/// assets/fonts/custom/. The TYPEFACE picker reads this.
List<TermFace> get termFaces => [...kTermFaces, ...customTermFaces];

/// Register, at runtime, every .ttf/.otf sitting in assets/fonts/custom/ so they
/// become usable by family name and show up in the picker — no pubspec edit per
/// font. Call once at startup, before the first frame and before the saved face
/// is applied. The family name is the filename without its extension; a file
/// that fails to load is skipped, never fatal.
Future<void> loadCustomFonts() async {
  try {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final files = manifest.listAssets().where((a) {
      final l = a.toLowerCase();
      return a.startsWith('assets/fonts/custom/') &&
          (l.endsWith('.ttf') || l.endsWith('.otf'));
    }).toList()
      ..sort();
    for (final a in files) {
      final name = a.split('/').last;
      final dot = name.lastIndexOf('.');
      final family = dot > 0 ? name.substring(0, dot) : name;
      if (termFaces.any((f) => f.family == family)) continue; // no duplicates
      try {
        final loader = FontLoader(family)..addFont(rootBundle.load(a));
        await loader.load();
        customTermFaces.add(TermFace(family, family.toUpperCase()));
      } catch (_) {
        // Unreadable / invalid font file — skip it.
      }
    }
  } catch (_) {
    // No manifest or no custom folder — nothing to load.
  }
}

/// A manual, on-disk refresh — for previewing a font you've dropped into the
/// folder but haven't committed/rebuilt yet. Startup's loadCustomFonts reads the
/// *bundled* copy; this reads the *actual* assets/fonts/custom/ directory in the
/// repo (found via the path lymnal recorded at install), so uncommitted fonts
/// show up too. Loads any new .ttf/.otf and returns how many faces it added.
Future<int> reloadCustomFontsFromDisk() async {
  var added = 0;
  try {
    final home = Platform.environment['HOME'];
    if (home == null) return 0;
    final repoFile = File('$home/.config/lymnal/repo.path');
    if (!repoFile.existsSync()) return 0;
    final repo = (await repoFile.readAsString()).trim();
    if (repo.isEmpty) return 0;
    final dir = Directory('$repo/elyxr/assets/fonts/custom');
    if (!dir.existsSync()) return 0;
    final files = dir.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      final l = f.path.toLowerCase();
      if (!(l.endsWith('.ttf') || l.endsWith('.otf'))) continue;
      final name = f.path.split(Platform.pathSeparator).last;
      final dot = name.lastIndexOf('.');
      final family = dot > 0 ? name.substring(0, dot) : name;
      if (termFaces.any((t) => t.family == family)) continue; // already have it
      try {
        final bytes = await f.readAsBytes();
        final loader = FontLoader(family)
          ..addFont(Future.value(ByteData.sublistView(bytes)));
        await loader.load();
        customTermFaces.add(TermFace(family, family.toUpperCase()));
        added++;
      } catch (_) {
        // Unreadable / invalid font file — skip it.
      }
    }
  } catch (_) {
    // No repo path / no folder — nothing to refresh.
  }
  return added;
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
  Accent.red: const AccentSpec(18, 1.00, 0.223, 0.56),
  Accent.amber: const AccentSpec(82, 1.00, 0.207, 0.70),
  Accent.green: const AccentSpec(145, 1.00, 0.244, 0.56),
  Accent.cyan: const AccentSpec(195, 0.95, 0.168, 0.62),
  Accent.blue: const AccentSpec(255, 1.00, 0.212, 0.56),
  Accent.purple: const AccentSpec(307, 1.10, 0.258, 0.58),
  Accent.pink: const AccentSpec(352, 0.95, 0.190, 0.70),
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
  // How hard the tube blooms — grows as the saturation drag reaches its top, so
  // maxing the colour also brightens the glow overall. Read by the chassis.
  late final double bloom;
  // A separate, intense glow quality that takes over once the colour has hit its
  // chroma ceiling and the drag is only adding glow. Ramped (glowT²) so it stays
  // near zero through normal saturation and then blooms hard at the very top —
  // and the chassis reads it to throw a real glow *past* its own metal edge.
  late final double edgeGlow;

  void _build() {
    final h = _s.mono ? 0.0 : _s.hue;
    final maxC = _s.maxCeil;
    // The accent swatch itself. trueArgb clamps the requested chroma to the
    // hue's in-gamut ceiling *holding the hue*, so a punchy max-saturation drag
    // reaches the richest true colour instead of drifting when it would clip.
    if (_s.mono) {
      a = _c(oklchArgb(monoL, 0, 0));
    } else {
      a = _c(trueArgb(_s.baseL, h, accentChroma(_s.chromaMul, maxC, sat)));
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
    // 0 at neutral saturation, 1 as the drag reaches its top (~3.2). Past a
    // colour's chroma ceiling the drag stops adding saturation, so from there it
    // drives the glow instead: brighter key text, a hotter glow, a bigger bloom.
    final glowT = _s.mono ? 0.0 : ((sat - 1.0) / 2.2).clamp(0.0, 1.0).toDouble();
    if (dark) {
      final glowBoost = sat < 1.8 ? sat : 1.8;
      bright = _s.mono
          ? _c(oklchArgb(0.90, 0, 0))
          : _c(trueArgb(0.88 + 0.06 * glowT, h, maxC * 0.9 * glowBoost));
      soft = _c(trueArgb(0.34, h, maxC * 0.55 * wc));
      mid = _c(trueArgb(0.66, h, maxC * wc));
      dim = _c(trueArgb(0.44, h, maxC * 0.85 * wc));
      foot = _c(trueArgb(0.52, h, maxC * 0.70 * wc));
      glow = _c(trueArgb(0.60 + 0.07 * glowT, h, maxC * wc));
      tubeBg = _c(trueArgb(0.085, h, 0.020 * wc));
      bloom = 0.07 + 0.30 * glowT;
      edgeGlow = glowT * glowT;
    } else {
      bright = _s.mono
          ? _c(oklchArgb(0.24, 0, 0))
          : _c(trueArgb(0.28, h, maxC * wc));
      soft = _c(trueArgb(0.42, h, maxC * 0.80 * wc));
      mid = _c(trueArgb(0.50, h, maxC * 0.80 * wc));
      dim = _c(trueArgb(0.80, h, maxC * 0.40 * wc));
      foot = _c(trueArgb(0.62, h, maxC * 0.60 * wc));
      glow = _c(trueArgb(0.55, h, maxC * wc));
      // A soft tinted paper, not stark white — a light wash of the accent so the
      // background sits with the theme instead of glaring. (mono stays neutral.)
      tubeBg = _c(trueArgb(0.930, h, 0.060 * wc));
      bloom = 0.04 * glowT;
      edgeGlow = glowT * glowT * 0.6;
    }
  }

  /// Accent at a given alpha fraction (for the faint bands and glows).
  Color aAlpha(double f) => a.withValues(alpha: f);
}

/// The visible chassis: portrait, not resizable. It carries the Galaxy S22
/// The DESKTOP window size, in logical pixels (used by the native runner /
/// window_manager). It is NOT the phone size. On a PHONE the app renders at the
/// device's own full resolution — the whole screen, e.g. 1440 × 3088 px — with
/// no fixed box and no down-scaling (see app.dart: the chassis fills the device
/// directly). Do NOT force a fixed phone size from these constants; the phone
/// owns its dimensions.
const double kAppWidth = 440;
const double kAppHeight = 944;

/// Transparent breathing room added *around* the chassis on every side. The
/// window is bigger than the chassis by this much — the chassis stays full
/// size and this extra ring is pure transparent space for the glow to bleed
/// into. It does NOT shrink the app; it enlarges the window.
const double kGlowMargin = 56;

/// The real OS window: the chassis plus the transparent glow ring on all sides.
/// The native runner is sized to exactly this, so the chassis inside renders at
/// full 440×884 with the ring as spare room — no downscaling of the app.
const double kWindowWidth = kAppWidth + kGlowMargin * 2;
const double kWindowHeight = kAppHeight + kGlowMargin * 2;
