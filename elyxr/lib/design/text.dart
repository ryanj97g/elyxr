// Small text-style helpers, so each of the three faces is used for its one job
// (DESIGN.md · Type) without repeating the family name everywhere.
//
// One knob per face scales every call site at once (§ readability). The glass
// (terminal) text carries the most reading, so it's scaled the hardest; the
// chassis labels sit on the metal at a fixed control size, so they're nudged
// only a little to keep the rails from breaking. Turn these to taste — every
// size in the app follows.

import 'package:flutter/widgets.dart';

import 'tokens.dart';

const double kGlassScale = 1.3; // VT323 body/terminal text
const double kChassisScale = 1.12; // Chakra Petch control labels
const double kMonoScale = 1.18; // IBM Plex Mono ticker/version

/// VT323 — everything on the glass.
TextStyle glass(double size, Color color, {double height = 1.0, double? spacing}) =>
    TextStyle(
      fontFamily: Fonts.glass,
      fontFamilyFallback: Fonts.fallback,
      fontSize: size * kGlassScale,
      color: color,
      height: height,
      letterSpacing: spacing,
      decoration: TextDecoration.none,
    );

/// Chakra Petch — chassis labels, section headers, rail buttons.
TextStyle chassis(double size, Color color,
        {FontWeight weight = FontWeight.w600, double spacing = 0.1}) =>
    TextStyle(
      fontFamily: Fonts.chassis,
      fontFamilyFallback: Fonts.fallback,
      fontSize: size * kChassisScale,
      color: color,
      fontWeight: weight,
      letterSpacing: size * kChassisScale * spacing,
      decoration: TextDecoration.none,
    );

/// IBM Plex Mono — the ticker and version strings. Nothing else.
TextStyle mono(double size, Color color,
        {FontWeight weight = FontWeight.w400, double spacing = 0.1}) =>
    TextStyle(
      fontFamily: Fonts.mono,
      fontFamilyFallback: Fonts.fallback,
      fontSize: size * kMonoScale,
      color: color,
      fontWeight: weight,
      letterSpacing: size * kMonoScale * spacing,
      decoration: TextDecoration.none,
    );
