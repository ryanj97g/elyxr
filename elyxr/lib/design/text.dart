// Small text-style helpers, so each of the three faces is used for its one job
// (DESIGN.md · Type) without repeating the family name everywhere.

import 'package:flutter/widgets.dart';

import 'tokens.dart';

/// VT323 — everything on the glass.
TextStyle glass(double size, Color color, {double height = 1.0, double? spacing}) =>
    TextStyle(
      fontFamily: Fonts.glass,
      fontSize: size,
      color: color,
      height: height,
      letterSpacing: spacing,
    );

/// Chakra Petch — chassis labels, section headers, rail buttons.
TextStyle chassis(double size, Color color,
        {FontWeight weight = FontWeight.w600, double spacing = 0.1}) =>
    TextStyle(
      fontFamily: Fonts.chassis,
      fontSize: size,
      color: color,
      fontWeight: weight,
      letterSpacing: size * spacing,
    );

/// IBM Plex Mono — the ticker and version strings. Nothing else.
TextStyle mono(double size, Color color,
        {FontWeight weight = FontWeight.w400, double spacing = 0.1}) =>
    TextStyle(
      fontFamily: Fonts.mono,
      fontSize: size,
      color: color,
      fontWeight: weight,
      letterSpacing: size * spacing,
    );
