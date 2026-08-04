import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elyxr/design/tokens.dart';
import 'package:elyxr/util/format.dart';
import 'package:elyxr/util/phrase.dart';

void main() {
  group('phrase', () {
    test('is deterministic for the same device+client', () {
      final a = phraseFor('probookrjg', 'elyxr/1.0.0');
      final b = phraseFor('probookrjg', 'elyxr/1.0.0');
      expect(a, b);
    });

    test('is four distinct words from the list', () {
      final words = phraseFor('probookrjg', 'elyxr/1.0.0').split(' ');
      expect(words.length, 4);
      expect(words.toSet().length, 4, reason: 'no repeats');
      for (final w in words) {
        expect(kPhraseWords.contains(w), isTrue);
      }
    });

    test('differs for a different device', () {
      expect(phraseFor('probookrjg', 'elyxr/1.0.0'),
          isNot(phraseFor('otherbox', 'elyxr/1.0.0')));
    });

    test('matches the cross-language vector lymnal derives', () {
      // lymnal's pairing.rs asserts the same string for the same input.
      expect(phraseFor('probookrjg', 'elyxr/1.0.0'), 'fern violet anchor saffron');
    });
  });

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
      expect(p.a, const Color(0xFF5FD18A));
      expect(p.ink, const Color(0xFF04120A));
    });

    test('phosphor bright is mix(accent, 0.55) in dark mode', () {
      final p = Palette(Accent.green, true);
      // mix(#5fd18a, 0.55): r=0x5f+(255-0x5f)*.55 ≈ 0xb2, etc.
      final b = p.bright;
      int ch(double v) => (v * 255).round();
      expect(ch(b.r), (0x5f + (255 - 0x5f) * 0.55).round());
      expect(ch(b.g), (0xd1 + (255 - 0xd1) * 0.55).round());
      expect(ch(b.b), (0x8a + (255 - 0x8a) * 0.55).round());
    });

    test('light mode uses the fixed phosphor roles', () {
      final p = Palette(Accent.green, false);
      expect(p.bright, const Color(0xFF0D1A12));
      expect(p.tubeBg, const Color(0xFFE8EFE9));
    });

    test('every accent resolves nine metal shades', () {
      for (final a in Accent.values) {
        final p = Palette(a, true);
        expect([p.m1, p.m2, p.m3, p.mb, p.mh, p.mt, p.ml, p.mv1, p.mv2].length, 9);
      }
    });
  });
}
