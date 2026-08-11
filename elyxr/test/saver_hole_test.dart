// The screensaver draws the music player over the rain. Two things about that are
// worth pinning, because both fail quietly:
//
//  - the copy has to land exactly on the real deck's box, which is what a
//    LayerLink is for — if it ever drifted, the controls would sit off from where
//    they are normally and you'd only find out by looking;
//  - the copy has to be reachable, and the rain must not eat its taps.
//
// The saver used to clip a hole in the rain instead. That's gone: the rain covers
// everything and the player is painted on top of it.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elyxr/design/tokens.dart';
import 'package:elyxr/widgets/deck_slot.dart';
import 'package:elyxr/widgets/nostalgia/matrix_rain.dart';
import 'package:elyxr/widgets/nostalgia/saver_layer.dart';

void main() {
  late DeckSlotRect rect;
  late int woke;
  late double volume;

  setUp(() {
    rect = DeckSlotRect();
    woke = 0;
    volume = 0;
  });

  // A stand-in for the tube: content with the deck slot in it, the saver over the
  // top. The deck band is deliberately NOT at the origin, so a copy positioned by
  // bad arithmetic instead of by the link would land visibly wrong.
  Widget harness({double top = 90, double height = 70}) => MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            height: 500,
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  top: top,
                  width: 400,
                  height: height,
                  child: DeckSlot(
                    notifier: rect,
                    child: const ColoredBox(
                        key: Key('real'), color: Color(0xFF102030)),
                  ),
                ),
                Positioned.fill(
                  child: SaverLayer(
                    palette: Palette(Accent.green, true),
                    deckRect: rect,
                    onWake: () => woke++,
                    onVolume: (d) => volume += d,
                    deckBuilder: (_) => const ColoredBox(
                        key: Key('copy'), color: Color(0xFF204060)),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  testWidgets('the deck reports its box', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    expect(rect.value, isNotNull);
    expect(rect.value!.size, const Size(400, 70));
  });

  testWidgets('the copy lands exactly on the real deck, not near it',
      (tester) async {
    await tester.pumpWidget(harness(top: 90, height: 70));
    await tester.pump();
    await tester.pump(); // the follower attaches once the target has a layer
    // Measure the copy's CONTENT, not the follower: a follower's own box is its
    // layout position, and the link's transform applies to what's inside it.
    final real = tester.getRect(find.byKey(const Key('real')));
    final copy = tester.getRect(find.byKey(const Key('copy')));
    expect(copy, kDeckPadding.deflateRect(real),
        reason: 'the saver copy is offset from the deck it mirrors');
  });

  testWidgets('it still lands exactly when the deck moves and resizes',
      (tester) async {
    // The deck changes height in real use (idle bar vs full player). A copy that
    // only matched at one size would be the bug that shows up mid-song.
    await tester.pumpWidget(harness(top: 90, height: 70));
    await tester.pump();
    await tester.pump();
    await tester.pumpWidget(harness(top: 140, height: 120));
    await tester.pump();
    await tester.pump();
    expect(tester.getRect(find.byKey(const Key('copy'))),
        kDeckPadding.deflateRect(tester.getRect(find.byKey(const Key('real')))));
  });

  testWidgets('the rain covers everything — no hole is cut in it',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    final rain = tester.getRect(find.byType(MatrixRain));
    final saver = tester.getRect(find.byType(SaverLayer));
    expect(rain, saver, reason: 'the rain no longer fills the tube');
  });

  testWidgets('a tap on the rain wakes the saver', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    final box = tester.getRect(find.byType(SaverLayer));
    await tester.tapAt(Offset(box.center.dx, box.bottom - 20));
    await tester.pump();
    expect(woke, 1);
  });

  testWidgets('the wheel adjusts volume without waking the tube',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    final box = tester.getRect(find.byType(SaverLayer));
    final at = Offset(box.center.dx, box.bottom - 20);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    tester.binding.handlePointerEvent(pointer.hover(at));
    tester.binding.handlePointerEvent(pointer.scroll(const Offset(0, -20)));
    await tester.pump();
    expect(volume, greaterThan(0), reason: 'scrolling up did not raise volume');
    expect(woke, 0, reason: 'a scroll is not a dismissal');
  });

  testWidgets('with no reported deck the saver is just the screensaver',
      (tester) async {
    rect.value = null;
    await tester.pumpWidget(MaterialApp(
      home: SizedBox(
        width: 400,
        height: 400,
        child: SaverLayer(
          palette: Palette(Accent.green, true),
          deckRect: rect,
          onWake: () => woke++,
          onVolume: (d) => volume += d,
          deckBuilder: (_) => const ColoredBox(color: Color(0xFF204060)),
        ),
      ),
    ));
    await tester.pump();
    expect(find.byType(CompositedTransformFollower), findsNothing);
    await tester.tapAt(const Offset(20, 20));
    await tester.pump();
    expect(woke, 1);
  });
}
