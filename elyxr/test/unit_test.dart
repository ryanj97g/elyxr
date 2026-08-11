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
    test('green is the default accent with its exact colours', () {
      final p = Palette(Accent.green, true);
      expect(p.a, const Color(0xFF3B8841));
      expect(p.ink, const Color(0xFFFFFFFF));
    });

    test('phosphor bright in dark mode', () {
      final p = Palette(Accent.green, true);
      expect(p.bright, const Color(0xFF66FC74));
    });

    test('light mode uses the fixed phosphor roles', () {
      final p = Palette(Accent.green, false);
      expect(p.bright, const Color(0xFF003405));
      expect(p.tubeBg, const Color(0xFFD0F3D0));
    });

    test('every accent resolves nine metal shades', () {
      for (final a in Accent.values) {
        final p = Palette(a, true);
        expect([p.m1, p.m2, p.m3, p.mb, p.mh, p.mt, p.ml, p.mv1, p.mv2].length, 9);
      }
    });
  });
}
