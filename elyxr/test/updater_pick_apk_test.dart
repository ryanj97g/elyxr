// The updater reads which APK is published rather than fetching a fixed name.
// Picking the right asset is the whole basis for "is there anything newer than
// me", so it gets tested directly.

import 'package:flutter_test/flutter_test.dart';
import 'package:elyxr/state/updater.dart';

Map<String, dynamic> asset(String name) => {
      'name': name,
      'browser_download_url': 'https://example.invalid/$name',
    };

void main() {
  test('takes the numbered APK', () {
    final p = UpdateController.pickApk([asset('elyxr-350.apk')]);
    expect(p?.build, 350);
    expect(p?.url, 'https://example.invalid/elyxr-350.apk');
  });

  test('takes the highest build when several are present', () {
    final p = UpdateController.pickApk(
        [asset('elyxr-9.apk'), asset('elyxr-350.apk'), asset('elyxr-121.apk')]);
    expect(p?.build, 350);
  });

  test('compares numerically, not as text — 90 is not newer than 350', () {
    final p = UpdateController.pickApk([asset('elyxr-350.apk'), asset('elyxr-90.apk')]);
    expect(p?.build, 350);
  });

  test('ignores the unnumbered file, whose name proves nothing', () {
    final p = UpdateController.pickApk([asset('elyxr.apk'), asset('elyxr-12.apk')]);
    expect(p?.build, 12);
  });

  test('null when the release carries no numbered APK at all', () {
    expect(UpdateController.pickApk([asset('elyxr.apk')]), isNull);
    expect(UpdateController.pickApk([asset('elyxr-setup-350.exe')]), isNull);
    expect(UpdateController.pickApk(const []), isNull);
  });

  test('survives junk in the asset list instead of throwing', () {
    final p = UpdateController.pickApk(
        ['nonsense', 42, {'name': 'elyxr-7.apk'}, asset('elyxr-8.apk')]);
    expect(p?.build, 8);
  });
}
