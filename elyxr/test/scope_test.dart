// The oscilloscope in the bottom band of the tube: where it's allowed to draw,
// and what it turns samples into.
//
// The geometry half of this exists because the obvious inset is the wrong one.
// A cradle crosses the tube's bottom edge kCradleSpan in from the side, so that
// looks like the clearance the band needs — but the driver's centre sits inside
// the tube, so the hole is most of a circle and keeps widening above that
// crossing, reaching kCradleReach at the driver's own height, which is inside the
// band. Inset by the crossing and the trace runs under metal at exactly the
// height it's drawn at. So the test doesn't check a number, it checks containment
// against the real tube outline.
//
// The signal half pins triggering and gain, which are the two things that decide
// whether a scope reads as an instrument or as noise, and which are both
// invisible in code review.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elyxr/design/chassis.dart';
import 'package:elyxr/design/tokens.dart';
import 'package:elyxr/state/scope_trace.dart';
import 'package:elyxr/widgets/scope.dart';

/// A window of a sine at [amp], starting at [phase] radians.
Float64List _sine(double amp, {double phase = 0, double hz = 440}) {
  final w = Float64List(1024);
  for (var i = 0; i < w.length; i++) {
    w[i] = amp * math.sin(phase + 2 * math.pi * hz * i / 44100);
  }
  return w;
}

double _peakOf(List<double> v) {
  var p = 0.0;
  for (final x in v) {
    if (x.abs() > p) p = x.abs();
  }
  return p;
}

void main() {
  group('where the band is', () {
    // Portrait like the real chassis, plus a couple of shapes it isn't, so the
    // containment holds by construction rather than at one size.
    const sizes = [
      Size(422, 700),
      Size(422, 918),
      Size(360, 500),
      Size(700, 900),
    ];

    test('a cradle is wider above the bottom edge than on it', () {
      // The whole reason the band is inset by kCradleReach. If this ever stops
      // being true the comment on kCradleReach is wrong and so is the band.
      expect(kCradleReach, greaterThan(kCradleSpan));
    });

    test('every point of the band is inside the glass', () {
      for (final s in sizes) {
        final glass = notchedTubePath(s.width, s.height, corner: 14);
        final band = scopeBand(s.width, s.height);
        expect(band.width, greaterThan(24), reason: 'no room to draw in at $s');
        for (var i = 0; i <= 24; i++) {
          for (var j = 0; j <= 8; j++) {
            final at = Offset(
              band.left + band.width * i / 24,
              band.top + band.height * j / 8,
            );
            expect(glass.contains(at), isTrue,
                reason: 'the band reaches $at, which is not glass, at $s');
          }
        }
      }
    });

    test('the band is exactly the room the content inset gives up', () {
      for (final s in sizes) {
        expect(scopeBand(s.width, s.height).top,
            closeTo(s.height - Tube.contentBottomInset, 0.001));
      }
    });

    test('the band clears the tube border and its bezel ring', () {
      // 1px border plus a 3px ring inset 1px — 4px of frame at the bottom.
      for (final s in sizes) {
        expect(s.height - scopeBand(s.width, s.height).bottom,
            greaterThan(4.0));
      }
    });
  });

  group('what it draws', () {
    test('a full-scale signal fills most of the band, and no more', () {
      final t = scopeTrace(_sine(1.0), 0);
      expect(t.points.length, kScopePoints);
      expect(_peakOf(t.points), inInclusiveRange(0.80, 0.93),
          reason: 'the trace should nearly fill the band without clipping');
    });

    test('silence is a flat line, not amplified noise', () {
      final t = scopeTrace(Float64List(1024), 0);
      expect(_peakOf(t.points), 0.0);
      expect(t.peak, 0.0);
    });

    test('a quiet passage still moves, but reads as quiet', () {
      // Below the floor, so the gain stops chasing it and the trace shrinks.
      final quiet = _peakOf(scopeTrace(_sine(0.02), 0).points);
      final loud = _peakOf(scopeTrace(_sine(1.0), 0).points);
      expect(quiet, greaterThan(0.02), reason: 'a quiet passage went invisible');
      expect(quiet, lessThan(loud * 0.5),
          reason: 'quiet was normalised up until it looked as loud as loud');
    });

    test('the rolling peak holds across frames, so the gain cannot pump', () {
      // A quiet window straight after a loud one is drawn against the loud peak
      // and reads quiet; only as that peak decays does it come back up.
      final t = scopeTrace(_sine(0.02), 1.0);
      expect(t.peak, closeTo(0.99, 0.001));
      expect(_peakOf(t.points), lessThan(0.05));
    });

    test('the peak decays on a silent window instead of sticking', () {
      final t = scopeTrace(Float64List(1024), 1.0);
      expect(t.peak, closeTo(0.99, 0.001));
    });

    test('the trace starts on a rising zero crossing, not wherever the window did',
        () {
      // A window that opens at full amplitude. Untriggered, the first point would
      // be the top of the trace; triggered, it starts near zero and climbs.
      final t = scopeTrace(_sine(1.0, phase: math.pi / 2), 0);
      expect(t.points.first.abs(), lessThan(0.2),
          reason: 'the trace did not start at a zero crossing — it will slide '
              'left and right every frame');
      expect(t.points[1], greaterThan(t.points.first),
          reason: 'it triggered on a falling crossing');
    });

    test('a window with no crossing to find still draws', () {
      // Entirely positive (a DC-ish offset): the trigger never arms, and the
      // fallback has to be a trace rather than an exception or an empty list.
      final w = Float64List(1024);
      for (var i = 0; i < w.length; i++) {
        w[i] = 0.5;
      }
      final t = scopeTrace(w, 0);
      expect(t.points.length, kScopePoints);
      expect(_peakOf(t.points), greaterThan(0.5));
    });
  });

  group('how it lands on the glass', () {
    // 422 wide is the real tube: the chassis is 440 with 9 of padding each side.
    // It matters here because it puts the band's centre on a whole pixel, so a
    // true mirror is exact rather than a subpixel argument.
    const w = 422, h = 918;

    final size = Size(w.toDouble(), h.toDouble());
    final band = scopeBand(size.width, size.height);

    Future<_Raster> render(List<double> wave) async {
      final rec = ui.PictureRecorder();
      paintScope(Canvas(rec), size, Palette(Accent.green, true), wave);
      final img = rec.endRecording().toImageSync(w, h);
      final bytes = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      return _Raster(bytes!, w, h);
    }

    // Something with no symmetry of its own, so any symmetry in the result came
    // from the mirror rather than from the signal.
    final lopsided = List<double>.generate(
        kScopePoints, (i) => math.sin(i * 0.31) * (0.2 + 0.8 * i / kScopePoints));

    test('the two halves are mirror images', () async {
      final r = await render(lopsided);
      expect(band.center.dx % 1, 0,
          reason: 'the band centre moved off a whole pixel; see the note above');
      var compared = 0;
      for (var x = 0; x < w; x++) {
        final ink = r.columnInk(x, band);
        final mirrored = r.columnInk(w - 1 - x, band);
        // Proportional, because the rasteriser's coverage is not bit-exact under
        // a negative scale — a true mirror still lands a fraction of a percent
        // apart. A mirror that were actually wrong would put a column against an
        // empty one or against a different part of the trace entirely, which is
        // tens of percent out, not tenths.
        expect(mirrored, closeTo(ink, ink * 0.03 + 3),
            reason: 'column $x and its mirror ${w - 1 - x} differ — the two '
                'halves are not the same trace');
        if (ink > 0) compared++;
      }
      expect(compared, greaterThan(100),
          reason: 'sanity: almost nothing was drawn, so symmetry proves nothing');
    });

    test('both traces run the full band, so neither tail is cut', () async {
      // Two complete traces crossing, rather than two halves meeting: each runs
      // from its own outer edge to the far one, and nothing fades. So the band's
      // outer columns carry as much ink as the middle does. Halving the traces or
      // fading their ends puts these columns near zero.
      final r = await render(lopsided);
      final inner = r.columnInk(band.center.dx.round(), band);
      for (final x in [
        band.left.ceil() + 1,
        band.right.floor() - 1,
      ]) {
        expect(r.columnInk(x, band), greaterThan(inner * 0.25),
            reason: 'column $x is nearly empty — a trace is being cut short or '
                'faded out before the cradle');
      }
    });

    test('it stays down in its band and off the terminal', () async {
      // The bloom is allowed to feather a few pixels past the band — that's the
      // point of a bloom. What must never happen is the scope painting up into
      // where the file rows are.
      final r = await render(lopsided);
      for (var y = 0; y < band.top - 12; y++) {
        expect(r.rowInk(y), 0,
            reason: 'the scope painted at y=$y, above its band at ${band.top}');
      }
    });

    test('with nothing playing it draws a resting line, not nothing', () async {
      final r = await render(const <double>[]);
      expect(r.rowInk(band.center.dy.round()), greaterThan(0),
          reason: 'the idle scope is invisible — it should read as switched on');
      expect(r.rowInk(band.top.round() + 2), 0,
          reason: 'the resting state is a line, not a filled band');
    });
  });
}

/// Raw pixels, with the two questions this file asks of them.
class _Raster {
  final ByteData bytes;
  final int w, h;
  const _Raster(this.bytes, this.w, this.h);

  int _alpha(int x, int y) => bytes.getUint8((y * w + x) * 4 + 3);

  /// Total alpha down one column, within [band]'s rows.
  double columnInk(int x, Rect band) {
    var sum = 0.0;
    for (var y = band.top.floor(); y < band.bottom.ceil() && y < h; y++) {
      sum += _alpha(x, y);
    }
    return sum;
  }

  /// Total alpha across one row.
  int rowInk(int y) {
    var sum = 0;
    for (var x = 0; x < w; x++) {
      sum += _alpha(x, y);
    }
    return sum;
  }
}
