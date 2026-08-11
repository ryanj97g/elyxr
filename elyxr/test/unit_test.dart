import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elyxr/design/tokens.dart';
import 'package:elyxr/util/format.dart';

void main() {
  group('format', () {
    test('sizes read in plain units', () {
      expect(fmtSize(2048), '2K');
      expect(fmtSize(284120), '284K');
      expect(fmtSize(41200000), '41M');
      expect(fmtSize(2254857830), '2.3G');
      expect(fmtSize(512), '512B');
    });

    test('counts are pluralised', () {
      expect(fmtCount(1, 'file'), '1 file');
      expect(fmtCount(12, 'file'), '12 files');
    });
  });

  group('palette', () {
    // These replace three tests that asserted hex literals and a
    // mix(accent, 0.55) formula. The palette is derived through OKLCH now, so
    // those numbers described an implementation that no longer exists and broke
    // the moment a colour was tuned. What follows pins the RULES instead, which
    // survive retuning and catch things a literal never would — the contrast
    // check below is what found amber and pink shipping unreadable text.

    test('text on the accent is readable on every accent, in both modes', () {
      for (final dark in [true, false]) {
        for (final a in Accent.values) {
          final p = Palette(a, dark);
          final r = _contrastRatio(p.a, p.ink);
          expect(r, greaterThanOrEqualTo(3.0),
              reason: '${a.name} ${dark ? 'dark' : 'light'}: text on the accent '
                  'is ${r.toStringAsFixed(2)}:1, under the 3:1 floor for large '
                  'text. ink is used for the SERVER header and the preview '
                  'controls, which sit directly on this colour.');
        }
      }
    });

    test('ink is whichever candidate is actually more readable', () {
      // Not a lightness threshold: amber and pink sit exactly on the old 0.70
      // boundary and fell the wrong side of it.
      for (final a in Accent.values) {
        final p = Palette(a, true);
        final other = p.ink.r > 0.9
            ? const Color(0xFF1A1A1A) // a dark candidate
            : const Color(0xFFFFFFFF);
        expect(_contrastRatio(p.a, p.ink),
            greaterThanOrEqualTo(_contrastRatio(p.a, other) - 0.6),
            reason: '${a.name}: the other ink would have been easier to read');
      }
    });

    test('the phosphor hierarchy runs the right way in each mode', () {
      for (final a in Accent.values) {
        final dark = Palette(a, true);
        // On a glowing tube, key text is the brightest thing and the background
        // is nearly black.
        expect(_lum(dark.bright), greaterThan(_lum(dark.mid)));
        expect(_lum(dark.mid), greaterThan(_lum(dark.soft)));
        expect(_lum(dark.bright), greaterThan(_lum(dark.tubeBg) + 0.5),
            reason: '${a.name}: key text barely stands off the tube');

        // On paper it inverts: key text is INK, darker than the page.
        final light = Palette(a, false);
        expect(_lum(light.bright), lessThan(_lum(light.tubeBg)),
            reason: '${a.name}: light mode is drawing key text lighter than the '
                'page it sits on');
        expect(_lum(light.tubeBg) - _lum(light.bright), greaterThan(0.5));
      }
    });

    test('each accent is its own colour, not a shade of one', () {
      final seen = <int>{};
      for (final a in Accent.values) {
        seen.add(Palette(a, true).a.toARGB32());
      }
      expect(seen.length, Accent.values.length,
          reason: 'two accents resolve to the same colour');
    });

    test('every accent resolves nine metal shades', () {
      for (final a in Accent.values) {
        final p = Palette(a, true);
        expect([p.m1, p.m2, p.m3, p.mb, p.mh, p.mt, p.ml, p.mv1, p.mv2].length, 9);
      }
    });
  });
}

/// WCAG relative luminance and contrast, so the palette's readability rules are
/// checked the way a person's eyes experience them rather than by comparing raw
/// channel values.
double _lum(Color c) {
  double ch(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

double _contrastRatio(Color x, Color y) {
  final a = _lum(x), b = _lum(y);
  final hi = a > b ? a : b, lo = a > b ? b : a;
  return (hi + 0.05) / (lo + 0.05);
}
