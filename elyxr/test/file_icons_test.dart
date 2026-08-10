// The browser's file-type classification and the icon each type resolves to. Worth
// pinning: these are pure functions the whole file tree leans on, and two of the
// tests here stop a whole class of silent breakage — a kind with no icon mapped,
// and a mapping that points at an SVG nobody ever drew.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:elyxr/design/file_icons.dart';
import 'package:elyxr/state/music.dart' show kAudioExts, kModuleExts;

void main() {
  test('a folder is a folder whatever it is called', () {
    expect(fileKindOf('MUSIC TEST!', isDir: true), FileKind.folder);
    // Even when the name carries a misleading extension.
    expect(fileKindOf('backup.zip', isDir: true), FileKind.folder);
  });

  test('extensions classify, and case does not matter', () {
    expect(fileKindOf('42mg.mp3'), FileKind.audio);
    expect(fileKindOf('42MG.MP3'), FileKind.audio);
    expect(fileKindOf('Screenshot_20260810_122008.jpg'), FileKind.image);
    expect(fileKindOf('holiday.MOV'), FileKind.video);
    expect(fileKindOf('lease.pdf'), FileKind.document);
    expect(fileKindOf('budget.xlsx'), FileKind.spreadsheet);
    expect(fileKindOf('deck.pptx'), FileKind.presentation);
    expect(fileKindOf('trove.tar.gz'), FileKind.archive);
    expect(fileKindOf('music.dart'), FileKind.code);
    expect(fileKindOf('README.md'), FileKind.text);
    expect(fileKindOf('config.toml'), FileKind.data);
    expect(fileKindOf('VT323.ttf'), FileKind.font);
    expect(fileKindOf('ubuntu.iso'), FileKind.disk);
    expect(fileKindOf('elyxr.apk'), FileKind.app);
  });

  // A tracker module is music to someone browsing for music, even though it needs
  // rendering before it plays.
  test('tracker modules count as audio', () {
    for (final n in ['song.xm', 'song.mod', 'song.s3m', 'song.it']) {
      expect(fileKindOf(n), FileKind.audio, reason: n);
    }
  });

  // '.ts' collides — TypeScript vs MPEG transport stream. The choice is
  // deliberate, so pin it rather than let it flip silently.
  test('.ts is TypeScript, and .m2ts covers the video case', () {
    expect(fileKindOf('app.ts'), FileKind.code);
    expect(fileKindOf('capture.m2ts'), FileKind.video);
  });

  test('an unknown extension is unknown, not a wrong guess', () {
    expect(fileKindOf('thing.qqq'), FileKind.unknown);
    expect(fileKindOf('noextension'), FileKind.unknown);
  });

  // A leading dot is a hidden file, not an extension — '.gitignore' is not a file
  // of type "gitignore".
  test('a dotfile is not classified by its name', () {
    expect(fileKindOf('.gitignore'), FileKind.unknown);
    expect(fileKindOf('.bashrc'), FileKind.unknown);
  });

  test("the server's mime type answers when the extension cannot", () {
    expect(fileKindOf('recording', mime: 'audio/mpeg'), FileKind.audio);
    expect(fileKindOf('clip', mime: 'video/mp4'), FileKind.video);
    expect(fileKindOf('scan', mime: 'image/png'), FileKind.image);
    expect(fileKindOf('paper', mime: 'application/pdf'), FileKind.document);
    expect(fileKindOf('notes', mime: 'text/plain'), FileKind.text);
  });

  test('a known extension beats a mime type that disagrees', () {
    // lymnal sniffing an .mp3 as octet-stream must not demote it to unknown.
    expect(fileKindOf('42mg.mp3', mime: 'application/octet-stream'),
        FileKind.audio);
  });

  // The classifier and the player keep separate lists — one decides what a file
  // LOOKS like, the other what it can PLAY. They are allowed to differ (a .sid
  // reads as music with no decoder behind it) but never in the direction that
  // matters: anything playable must read as audio, or the browser would show a
  // playable track as an unknown blob.
  test('everything the player can play reads as audio', () {
    for (final e in kAudioExts) {
      expect(fileKindOf('tune.$e'), FileKind.audio, reason: '.$e');
    }
  });

  test('every playable module is classified, none silently dropped', () {
    for (final e in kModuleExts) {
      expect(kExtKinds[e], FileKind.audio,
          reason: '.$e is playable but missing from kExtKinds');
    }
  });

  // These two have icons and read as music, but nothing decodes them. Pinned so
  // the state is deliberate rather than an oversight someone "fixes" by adding
  // them to the player's list, where they would fail at render time.
  test('sid and nsf read as music but are not claimed as playable', () {
    expect(fileKindOf('tune.sid'), FileKind.audio);
    expect(fileKindOf('tune.nsf'), FileKind.audio);
    expect(kAudioExts.contains('sid'), isFalse);
    expect(kAudioExts.contains('nsf'), isFalse);
    expect(kAudioExts.contains('ahx'), isFalse);
  });

  test('every kind has an icon, so none can fall through to nothing', () {
    for (final k in FileKind.values) {
      expect(kKindGlyphs[k], isNotNull, reason: 'no glyph mapped for $k');
    }
  });

  test('every mapped icon name is a file that actually exists', () {
    final names = {...kKindGlyphs.values, ...kExtGlyphs.values};
    for (final n in names) {
      expect(File('assets/icons/filetype/$n.svg').existsSync(), isTrue,
          reason: 'kExtGlyphs/kKindGlyphs points at a missing $n.svg');
    }
  });

  test('an extension icon wins over its kind icon', () {
    // .js is code, but it has a glyph of its own, so it must not fall back.
    expect(fileKindOf('app.js'), FileKind.code);
    expect(glyphNameFor('app.js'), 'js');
    // .rb is code with no glyph of its own, so it takes the kind's.
    expect(glyphNameFor('app.rb'), 'code');
    // A shell script is code, but reads better as a terminal.
    expect(glyphNameFor('build.sh'), 'terminal');
    // A folder is a folder before anything else.
    expect(glyphNameFor('archive.zip', isDir: true), 'folder');
  });

  test('the tracker and chiptune formats each keep their own glyph', () {
    for (final e in ['mod', 'xm', 's3m', 'it', 'stm', 'okt', 'med', '669',
                     'ahx', 'sid', 'nsf']) {
      expect(glyphNameFor('tune.$e'), e, reason: '.$e lost its own glyph');
    }
  });

  test('a kind resolves to its own asset, with the interpolation intact', () {
    expect(glyphAsset('audio'), 'assets/icons/filetype/audio.svg');
    expect(glyphAsset('js'), 'assets/icons/filetype/js.svg');
    for (final n in kKindGlyphs.values) {
      expect(glyphAsset(n), isNot(contains(r'$')));
    }
  });

  testWidgets('a glyph renders for a file, a folder and an unknown type',
      (tester) async {
    for (final probe in [
      ('42mg.mp3', false),
      ('MUSIC TEST!', true),
      ('thing.qqq', false),
    ]) {
      await tester.pumpWidget(MaterialApp(
        home: FileGlyph(
          name: probe.$1,
          isDir: probe.$2,
          size: 16,
          color: const Color(0xFF00FF66),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: probe.$1);
    }
  });
}
