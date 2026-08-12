// The speaker cradles: metal wrapping each bottom-corner driver, with the glass
// clipped away around it. This geometry can't be checked by eye in a test, but it
// CAN be checked exactly — Path.contains tells us which side of the glass edge a
// point falls on, so "the driver is fully in metal, with clearance" is a provable
// statement rather than a hopeful one. That is the whole reason this file exists:
// every previous attempt at this shape was tuned by eye and mismatched.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:elyxr/design/tokens.dart';

// A representative tube: the app is 440 wide, less the chassis padding, and the
// tube is most of the height.
const double _w = 422;
const double _h = 700;

/// Points on the circle of [radius] around [c].
Iterable<Offset> _ring(Offset c, double radius, {int n = 720}) =>
    Iterable.generate(
        n,
        (i) =>
            c +
            Offset(math.cos(2 * math.pi * i / n), math.sin(2 * math.pi * i / n)) *
                radius);

void main() {
  final glass = notchedTubePath(_w, _h, corner: 14);
  final leftC = driverCentre(_w, _h, left: true);
  final rightC = driverCentre(_w, _h, left: false);

  test('the glass still covers the screen it is supposed to', () {
    expect(glass.contains(Offset(_w / 2, _h / 2)), isTrue, reason: 'centre');
    expect(glass.contains(const Offset(_w / 2, 4)), isTrue, reason: 'top edge');
    // The bottom middle, between the two cradles, is still glass.
    expect(glass.contains(Offset(_w / 2, _h - 4)), isTrue, reason: 'bottom mid');
  });

  // The arc could bow the wrong way — toward the corner instead of away from it —
  // and still be a valid path. That would put the driver ON the glass, which is
  // the "screwing into glass" failure. This is the test that catches it.
  test('each driver sits entirely OUTSIDE the glass, on metal', () {
    for (final entry in {'left': leftC, 'right': rightC}.entries) {
      // The centre itself.
      expect(glass.contains(entry.value), isFalse,
          reason: '${entry.key} driver centre is on glass');
      // The whole basket, edge included.
      for (final p in _ring(entry.value, kDriverR)) {
        expect(glass.contains(p), isFalse,
            reason: '${entry.key} basket edge at $p is on glass');
      }
    }
  });

  test('the metal around each driver is at least kDriverMetal thick', () {
    for (final entry in {'left': leftC, 'right': rightC}.entries) {
      // Everything out to just inside the dome is still metal. If the glass edge
      // cut closer than this, the driver would have a thin spot beside it.
      for (final p in _ring(entry.value, kDomeR - 0.5)) {
        // Only meaningful inside the tube — past its edges is chassis metal
        // anyway (the rail band below, the case wall beside).
        if (p.dx <= 0 || p.dy >= _h || p.dx >= _w) continue;
        expect(glass.contains(p), isFalse,
            reason: '${entry.key} metal is thinner than kDriverMetal at $p');
      }
    }
  });

  test('the cradle swallows the corner — no sliver of glass left in it', () {
    for (final corner in [Offset(0.5, _h - 0.5), Offset(_w - 0.5, _h - 0.5)]) {
      expect(glass.contains(corner), isFalse, reason: 'glass at corner $corner');
    }
  });

  test('the glass comes back just outside each dome', () {
    // Sanity in the other direction: the cut is a dome, not a hole punched
    // through the whole bottom of the screen. Just beyond the dome, along the
    // diagonal into the tube, must be glass again.
    for (final c in [leftC, rightC]) {
      final inward = Offset(c.dx < _w / 2 ? 1 : -1, -1) / math.sqrt2;
      final p = c + inward * (kDomeR + 6);
      expect(glass.contains(p), isTrue, reason: 'no glass returning at $p');
    }
  });

  test('an inset outline (the edge light) still clears the drivers', () {
    // The music edge light draws the same outline inset a couple of px. Insetting
    // must shrink the domes too, or the light would cut across a driver.
    final inset = notchedTubePath(_w, _h, inset: 2, corner: 11);
    for (final c in [leftC, rightC]) {
      for (final p in _ring(c, kDriverR)) {
        expect(inset.contains(p), isFalse, reason: 'inset outline crosses $p');
      }
    }
  });
}
