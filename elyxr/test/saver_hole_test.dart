// The screensaver leaves a hole for the music deck. Painting a hole is easy to get
// looking right and easy to get WRONG in the way that matters: if the saver still
// absorbs clicks and scrolls over that region, the deck is visible but dead, which
// is worse than not sparing it at all.
//
// So these tests are about hit testing, not pixels — does a tap in the hole reach
// the widget underneath, and does a tap outside it still wake the saver.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elyxr/design/tokens.dart';
import 'package:elyxr/widgets/deck_slot.dart';
import 'package:elyxr/widgets/nostalgia/saver_layer.dart';

void main() {
  late DeckSlotRect rect;
  late int woke;
  late int deckTaps;
  late double volume;

  setUp(() {
    rect = DeckSlotRect();
    woke = 0;
    deckTaps = 0;
    volume = 0;
  });

  // The deck sits in a 200x60 band at the top; the saver covers the whole 400x400
  // and is told to spare that band.
  Widget harness() => MaterialApp(
        home: Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 400,
              height: 400,
              child: Stack(
                children: [
                  // Standing in for the tube content, with the deck in it.
                  Positioned(
                    left: 0,
                    top: 0,
                    width: 200,
                    height: 60,
                    child: DeckSlot(
                      notifier: rect,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => deckTaps++,
                        child: const ColoredBox(color: Color(0xFF102030)),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: SaverLayer(
                      palette: Palette(Accent.green, true),
                      deckRect: rect,
                      onWake: () => woke++,
                      onVolume: (d) => volume += d,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  testWidgets('the deck reports where it is', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump(); // let the post-frame report land
    expect(rect.value, isNotNull);
    expect(rect.value!.size, const Size(200, 60));
  });

  testWidgets('a tap in the hole reaches the deck and does NOT wake the saver',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    // Inside the deck band.
    await tester.tapAt(tester.getCenter(find.byType(DeckSlot)));
    await tester.pump();
    expect(deckTaps, 1, reason: 'the deck never got the tap');
    expect(woke, 0, reason: 'using the deck dismissed the saver');
  });

  testWidgets('a tap anywhere else wakes the saver', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    final box = tester.getRect(find.byType(SaverLayer));
    // Well below the deck band.
    await tester.tapAt(Offset(box.center.dx, box.bottom - 20));
    await tester.pump();
    expect(woke, 1);
    expect(deckTaps, 0);
  });

  testWidgets('the wheel adjusts volume from anywhere over the saver',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    final box = tester.getRect(find.byType(SaverLayer));
    final at = Offset(box.center.dx, box.bottom - 20);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    tester.binding.handlePointerEvent(pointer.hover(at));
    tester.binding
        .handlePointerEvent(pointer.scroll(const Offset(0, -20)));
    await tester.pump();
    expect(volume, greaterThan(0), reason: 'scrolling up did not raise volume');
    // And it must not have woken the tube — a scroll is not a dismissal.
    expect(woke, 0);
  });

  testWidgets('with no reported deck the saver simply covers everything',
      (tester) async {
    // The failure direction that matters: an unknown rect must not clip a hole
    // somewhere arbitrary. Nothing is spared, and the saver still works.
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
        ),
      ),
    ));
    await tester.pump();
    await tester.tapAt(const Offset(20, 20));
    await tester.pump();
    expect(woke, 1);
  });
}
