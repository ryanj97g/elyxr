// The shake thresholds. These are the whole feature: a bar set too low launches
// another app out of someone's pocket, and set too high the gesture never works.
// Neither is discoverable by reading the code, and testing it on a phone means
// shaking a phone, so the detector takes its clock as an argument and the numbers
// get pinned here instead.

import 'package:flutter_test/flutter_test.dart';

import 'package:elyxr/util/shake_to_tailscale.dart';

/// Feed a run of jolts [gapMs] apart, returning how many times it fired.
int fireCount(ShakeDetector d, int count, {int gapMs = 150, int from = 0}) {
  var fired = 0;
  for (var i = 0; i < count; i++) {
    if (d.feed(30.0, from + i * gapMs)) fired++;
  }
  return fired;
}

void main() {
  test('gravity alone is not a shake', () {
    final d = ShakeDetector();
    // A phone sitting on a table reads ~9.8 forever.
    for (var i = 0; i < 500; i++) {
      expect(d.feed(9.81, i * 20), isFalse);
    }
  });

  test('walking is not a shake', () {
    final d = ShakeDetector();
    // Brisk walking peaks around 13–15 m/s², well under the bar.
    for (var i = 0; i < 500; i++) {
      expect(d.feed(i.isEven ? 14.5 : 8.0, i * 20), isFalse);
    }
  });

  test('a deliberate shake fires once', () {
    final d = ShakeDetector();
    expect(fireCount(d, ShakeDetector.joltsToFire), 1);
  });

  test('three jolts are not enough', () {
    final d = ShakeDetector();
    expect(fireCount(d, ShakeDetector.joltsToFire - 1), 0);
  });

  test('jolts spread out past the window never accumulate', () {
    final d = ShakeDetector();
    // One hard knock every second — a bumpy car, not a shake.
    expect(fireCount(d, 30, gapMs: ShakeDetector.windowMs + 200), 0);
  });

  test('one long shake fires once, not continuously', () {
    final d = ShakeDetector();
    // Two seconds of shaking, still inside the cooldown after the first fire.
    final fired = fireCount(d, 20, gapMs: 100);
    expect(fired, 1, reason: 'a single shake triggered $fired times');
  });

  test('it can fire again after the cooldown', () {
    final d = ShakeDetector();
    expect(fireCount(d, ShakeDetector.joltsToFire), 1);
    final later = ShakeDetector.cooldownMs + 1000;
    expect(fireCount(d, ShakeDetector.joltsToFire, from: later), 1);
  });

  test('samples faster than the debounce count once, not many times', () {
    final d = ShakeDetector();
    // A 100Hz stream held above the threshold: without a debounce this would hit
    // the count almost instantly on one continuous jolt.
    var fired = 0;
    for (var i = 0; i < 3; i++) {
      if (d.feed(30.0, i * 10)) fired++;
    }
    expect(fired, 0);
  });

  test('magnitude is the vector length, gravity included', () {
    expect(shakeMagnitude(0, 0, 9.81), closeTo(9.81, 0.001));
    expect(shakeMagnitude(3, 4, 0), closeTo(5, 0.001));
    // The threshold has to sit above what gravity alone can produce on any axis.
    expect(ShakeDetector.jolt, greaterThan(shakeMagnitude(0, 0, 9.81) * 2));
  });
}
