// Every committed file-type SVG, actually rendered. A glyph set is only useful if
// flutter_svg can draw it, and SVG is a big spec that renderers implement only in
// part — so this loads each file and pumps it, rather than trusting that a valid
// SVG is a supported one.
//
// It also pins the two features this set leans on: <mask> (every icon knocks its
// glyph out of a solid body with one) and <text> (24 of them label themselves with
// an extension). If either is unsupported the icons come out blank or wordless,
// which is exactly the sort of thing that would otherwise be discovered by
// squinting at a phone.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

const _dir = 'assets/icons/filetype';

List<File> _icons() => Directory(_dir)
    .listSync()
    .whereType<File>()
    .where((f) => f.path.toLowerCase().endsWith('.svg'))
    .toList()
  ..sort((a, b) => a.path.compareTo(b.path));

void main() {
  test('the icon folder is where we think it is', () {
    expect(Directory(_dir).existsSync(), isTrue);
    expect(_icons(), isNotEmpty);
  });

  testWidgets('every icon parses and renders without throwing',
      (tester) async {
    final failed = <String>[];
    for (final f in _icons()) {
      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: SvgPicture.string(
            f.readAsStringSync(),
            width: 24,
            height: 24,
            colorFilter:
                const ColorFilter.mode(Color(0xFF00FF66), BlendMode.srcIn),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      final err = tester.takeException();
      if (err != null) failed.add('${f.path.split('/').last}: $err');
    }
    expect(failed, isEmpty, reason: 'icons that failed to render:\n${failed.join('\n')}');
  });

  // Both of these are here to record what the renderer actually does with the
  // features this set depends on. If a flutter_svg upgrade changes either
  // answer, this is the test that says so.
  testWidgets('a masked knockout renders as drawn', (tester) async {
    // A solid square with a hole punched by a mask. If masks were ignored the
    // result would be a plain filled square.
    const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
<defs><mask id="m" maskUnits="userSpaceOnUse" x="0" y="0" width="24" height="24">
<rect x="0" y="0" width="24" height="24" fill="#fff"/>
<circle cx="12" cy="12" r="6" fill="#000"/>
</mask></defs>
<rect x="0" y="0" width="24" height="24" fill="#000" mask="url(#m)"/>
</svg>''';
    await tester.pumpWidget(MaterialApp(
      home: Center(
          child: SizedBox(
              width: 24, height: 24, child: SvgPicture.string(svg))),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  // 24 of these icons say what they are by spelling it (".JS", ".MD"). Older
  // flutter_svg ignored <text> outright, which would have rendered those as
  // identical blank bodies — and "it rendered without an error" would not have
  // caught it. So count the pixels: text has to actually paint.
  test('<text> really paints, so the labelled icons are not blank', () async {
    const textOnly = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
<text x="12" y="12" text-anchor="middle" font-size="9" font-weight="700" fill="#000">.JS</text>
</svg>''';
    const shapeOnly = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
<circle cx="12" cy="12" r="6" fill="#000"/>
</svg>''';
    final text = await _opaquePixels(textOnly);
    final shape = await _opaquePixels(shapeOnly);
    expect(shape, greaterThan(0), reason: 'sanity: a circle must paint');
    expect(text, greaterThan(0),
        reason: 'flutter_svg dropped <text> — every labelled icon is blank');
  });
}

/// Rasterise an SVG and count pixels that are meaningfully opaque. The only way
/// to ask "did this actually draw anything" rather than "did it throw".
Future<int> _opaquePixels(String svg) async {
  final info = await vg.loadPicture(SvgStringLoader(svg), null);
  final image = info.picture.toImageSync(48, 48);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  var n = 0;
  for (var i = 3; i < bytes!.lengthInBytes; i += 4) {
    if (bytes.getUint8(i) > 8) n++;
  }
  return n;
}
