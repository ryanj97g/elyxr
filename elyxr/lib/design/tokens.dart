// The visual language of elyxr: a tinted metal chassis with a phosphor CRT tube.
// Named phosphor accents, each just a hue + chroma budget; every colour — the
// glowing tube in dark, the paper terminal in light, and the metal — is derived
// from that hue by the OKLCH engine (oklch.dart), gamut-true so a whole screen
// sits in one phosphor colour and stays that colour. A new accent is one row.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart' show AssetManifest, FontLoader, rootBundle;

import 'oklch.dart';

Color _c(int argb) => Color(argb);

// ---- the speaker cradles moulded into the chassis ----------------------------
//
// The chassis metal wraps each bottom-corner driver on its top and both sides,
// and the driver sits in a hole in that metal. There is no speaker "panel" drawn
// anywhere: the glass is clipped away in a dome at each bottom corner, and what
// shows through is the chassis Container's OWN gradient. So the metal around a
// driver is the same continuous surface as the rest of the case — not a matching
// shape painted to look like it, which is what a separate pod could never be.
//
// Both the dome (the glass edge) and the driver share one centre, so the metal
// between them is [kDriverMetal] thick everywhere by construction rather than by
// tuning. Everything below is in the TUBE's coordinate space — the cradle and the
// driver must be measured from the same origin or the seam comes back.

/// Radius of the driver's basket — the visible speaker.
const double kDriverR = 19;

/// Metal between the basket and the glass, all the way round the dome.
const double kDriverMetal = 10;

/// Radius of the dome the glass curves around: the basket plus its metal.
const double kDomeR = kDriverR + kDriverMetal;

/// How far a driver's centre sits in from the tube's side and bottom edges.
///
/// Less than [kDomeR] on purpose. If it equalled the dome radius the dome would
/// meet each edge at a single tangent point and the cradle would read as a ball
/// on a neck; pulling the centre in makes the dome cross both edges, so the metal
/// merges into the case over a real width and swallows the corner completely.
/// Still ≥ [kDriverR], so the basket itself never breaks the tube's edge.
const double kDriverInset = 20;

/// Half the chord the dome cuts on an edge it crosses.
final double _domeHalfChord =
    math.sqrt(kDomeR * kDomeR - kDriverInset * kDriverInset);

/// Where the dome crosses a side wall, measured up from the tube's bottom.
final double kCradleRise = kDriverInset + _domeHalfChord;

/// Where the dome crosses the bottom edge, measured in from a side wall.
final double kCradleSpan = kDriverInset + _domeHalfChord;

/// How far a cradle reaches in from a side wall at its WIDEST — which is not
/// [kCradleSpan].
///
/// Because the driver's centre sits inside the tube rather than on its corner,
/// the hole the dome cuts is most of a circle: it crosses the bottom edge
/// [kCradleSpan] in, but it keeps going and reaches its widest point [kDomeR]
/// out from the centre, level with it. Anything laid along the bottom band has to
/// clear THIS, not the bottom crossing — clearing only the crossing puts it under
/// metal at the driver's own height, where the cradle is at its widest.
const double kCradleReach = kDriverInset + kDomeR;

/// The centre of one bottom-corner driver, in tube coordinates. The dome the
/// glass curves around is concentric with it.
Offset driverCentre(double w, double h, {required bool left}) => Offset(
      left ? kDriverInset : w - kDriverInset,
      h - kDriverInset,
    );

/// The tube outline: a rounded rectangle whose two BOTTOM corners are cut away in
/// a dome, so the glass curves around the speaker cradled in the chassis metal
/// behind it. Shared by the tube's own clip and the music edge light so the two
/// always match. [inset] pulls the outline in from the edges; [corner] is the top
/// corner radius.
///
/// [inset] shrinks the domes with the outline, so an inset copy stays clear of the
/// drivers instead of cutting across them.
Path notchedTubePath(double w, double h, {double inset = 0, double corner = 12}) {
  final l = inset, t = inset, r = w - inset, b = h - inset;
  final cr = corner;
  final dome = Radius.circular(kDomeR - inset);
  final rise = kCradleRise - inset;
  final span = kCradleSpan - inset;
  return Path()
    ..moveTo(l + cr, t)
    ..lineTo(r - cr, t)
    ..arcToPoint(Offset(r, t + cr), radius: Radius.circular(cr))
    // Down the right wall to where the right dome cuts it, then around the
    // outside of that dome to the bottom edge.
    ..lineTo(r, b - rise)
    ..arcToPoint(Offset(r - span, b), radius: dome, clockwise: false)
    // Across the bottom between the two cradles, then around the left dome.
    ..lineTo(l + span, b)
    ..arcToPoint(Offset(l, b - rise), radius: dome, clockwise: false)
    ..lineTo(l, t + cr)
    ..arcToPoint(Offset(l + cr, t), radius: Radius.circular(cr))
    ..close();
}

/// Breathing room between the oscilloscope trace and the metal either side of it.
const double _kScopeGap = 4;

/// Clearance kept at the very bottom, so the trace stays off the tube's 1px
/// border and the 3px bezel ring just inside it.
const double _kScopeEdge = 5;

/// The empty band of glass between the two cradles, along the bottom of the tube.
///
/// It exists because the tube's content stops [kCradleRise] short of the bottom
/// (Tube.contentBottomInset) so that nothing is ever laid out under a dome. That
/// leaves the middle stretch between the two cradles unused, and the oscilloscope
/// lives in it. Inset by [kCradleReach] — the cradles' widest point, not where
/// they meet the bottom edge — so the trace is never clipped mid-stroke by one.
Rect scopeBand(double w, double h) => Rect.fromLTRB(
      kCradleReach + _kScopeGap,
      h - kCradleRise,
      w - kCradleReach - _kScopeGap,
      h - _kScopeEdge,
    );

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

  /// Faces tried, in order, for any character the chosen face doesn't have. All
  /// bundled, so a filename in any of these scripts renders from fonts we ship
  /// rather than from whatever the machine happens to have installed.
  ///
  /// Noto leads because its per-script files are designed and metric-matched as
  /// siblings: a folder holding Russian, Arabic, Thai and Korean names draws every
  /// one of them in the same typeface. Handjet and DotGothic16 are a backstop.
  ///
  /// Adding a script means bundling a face that has it and naming it here —
  /// nothing at the call sites changes.
  static const List<String> fallback = [
    'Noto Sans', // Latin, Greek, Cyrillic
    'Noto Sans Arabic',
    'Noto Sans Devanagari',
    'Noto Sans Thai',
    'Noto Sans JP', // kana and CJK ideographs
    'Noto Sans KR', // Hangul
    'Handjet',
    'DotGothic16',
  ];
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
  // A dot-matrix face that holds up at small sizes, which is most of what the
  // glass asks of a font. It's also the only pickable face with kana, so it's the
  // one that draws the Matrix rain's whole alphabet itself rather than handing
  // most of it to the fallback chain. Latin + Cyrillic + kana; no Arabic.
  TermFace('DotGothic16', 'DOTGOTHIC'),
  // The only pickable face that can draw Arabic — and it carries the GSUB table
  // the script needs, so letters join up instead of being printed as separate
  // stamps. Latin + Cyrillic + Arabic.
  //
  // Variable, like Orbitron: rendered at its default axis position, which is the
  // instance the specimen shows.
  TermFace('Handjet', 'HANDJET'),
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

/// Locate the repo's live `assets/fonts/custom/` on disk (desktop dev only).
/// There's no recorded repo path, so look where the app actually runs from: the
/// working directory and the executable's own location, plus their ancestors,
/// checking both `<dir>/assets/fonts/custom` (running from the elyxr package,
/// e.g. `flutter run`) and `<dir>/elyxr/assets/fonts/custom` (running from the
/// repo root or a build tree beside the source). Returns the first that exists,
/// or null on a packaged app with no source tree next to it.
Directory? _repoCustomFontDir() {
  final seeds = <String>{
    Directory.current.path,
    File(Platform.resolvedExecutable).parent.path,
  };
  for (final seed in seeds) {
    var d = Directory(seed);
    for (var i = 0; i < 12; i++) {
      for (final rel in const ['assets/fonts/custom', 'elyxr/assets/fonts/custom']) {
        final cand = Directory('${d.path}/$rel');
        if (cand.existsSync()) return cand;
      }
      final parent = d.parent;
      if (parent.path == d.path) break; // reached the filesystem root
      d = parent;
    }
  }
  return null;
}

/// A manual, on-disk refresh — for previewing a font you've dropped into the
/// folder but haven't committed/rebuilt yet. Startup's loadCustomFonts reads the
/// *bundled* copy; this reads the *actual* assets/fonts/custom/ directory in the
/// repo (located from where the app runs — see _repoCustomFontDir), so
/// uncommitted fonts show up too. Loads any new .ttf/.otf and returns how many
/// faces it added. Desktop only: a phone has no repo folder to scan.
Future<int> reloadCustomFontsFromDisk() async {
  if (Platform.isAndroid || Platform.isIOS) return 0;
  var added = 0;
  try {
    final dir = _repoCustomFontDir();
    if (dir == null) return 0;
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
        // Row padding. A file row is a touch target, so even TIGHT keeps a row
        // near the ~44px a finger needs; MID and ROOMY go past it.
        Density.tight => 9,
        Density.mid => 13,
        Density.roomy => 18,
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


/// Relative luminance, per WCAG — the sRGB channels linearised and weighted.
double _relLuminance(Color c) {
  double ch(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

/// WCAG contrast ratio between two colours, 1:1 (identical) to 21:1 (black on
/// white). Used to choose text that can actually be read on a given fill.
double _contrast(Color x, Color y) {
  final a = _relLuminance(x), b = _relLuminance(y);
  final hi = a > b ? a : b, lo = a > b ? b : a;
  return (hi + 0.05) / (lo + 0.05);
}

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
    // Text that sits on the accent fill — the SERVER header, the preview's
    // filename and its PREV/NEXT controls.
    //
    // Picked by MEASURING contrast against the accent, not by comparing its
    // lightness to a threshold. The threshold was `accL > 0.70`, and amber and
    // pink have a baseL of exactly 0.70 — so they fell on the wrong side by a
    // hair and got white text on a light fill: 2.71:1 on amber and 2.84:1 on
    // pink, under even the 3:1 floor for large text. Measuring can't be wrong at
    // a boundary, and it stays right when a hue is retuned.
    final darkInk = _c(oklchArgb(0.24, 0, 0));
    const whiteInk = Color(0xFFFFFFFF);
    ink = _contrast(a, darkInk) >= _contrast(a, whiteInk) ? darkInk : whiteInk;

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
      // Lifted across the board: the old values (0.34 / 0.66 / 0.44 / 0.52) read
      // as faded on the tube for anything that wasn't key text — an inactive
      // shuffle icon on `foot`, a secondary label on `soft`. Every terminal
      // element that isn't `bright` gets the same lift, so the hierarchy between
      // them is unchanged and only the floor comes up.
      soft = _c(trueArgb(0.46, h, maxC * 0.55 * wc));
      mid = _c(trueArgb(0.72, h, maxC * wc));
      dim = _c(trueArgb(0.54, h, maxC * 0.85 * wc));
      foot = _c(trueArgb(0.62, h, maxC * 0.70 * wc));
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

  /// The accent lifted a little toward white — a hot phosphor that still carries
  /// the picked hue. This is what the screensaver is drawn in: the rain's leading
  /// glyphs and the song title over it both read from here, so "everything on the
  /// saver is the colour you chose" is one definition rather than two that agree
  /// until someone edits one.
  ///
  /// Deliberately NOT [bright], which sits so light that purple and blue come out
  /// as plain white and the accent stops being visible at all.
  late final Color hot = Color.lerp(a, const Color(0xFFFFFFFF), 0.28)!;
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
