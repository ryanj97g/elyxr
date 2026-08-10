// The browser's file-type classification and the one table an icon set replaces.
// Worth pinning: every one of these is a pure function the whole file tree leans
// on, and the last test is what stops a new FileKind from shipping without
// anything to draw for it.

import 'package:flutter_test/flutter_test.dart';

import 'package:elyxr/design/file_icons.dart';

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

  test('every kind has something to draw', () {
    for (final k in FileKind.values) {
      final mark = kFileMarks[k];
      expect(mark, isNotNull, reason: 'no mark for $k');
      // Exactly one of the two forms, never both and never neither.
      expect(mark!.char != null || mark.icon != null, isTrue, reason: '$k');
      expect(mark.char != null && mark.icon != null, isFalse, reason: '$k');
    }
  });

  test('folders and files still draw what they always have', () {
    // Guards the promise that adding the seam changed nothing on screen. When a
    // real set lands these become icons and this test is the one to update.
    expect(kFileMarks[FileKind.folder]!.char, '█');
    expect(kFileMarks[FileKind.audio]!.char, '▫');
  });
}
