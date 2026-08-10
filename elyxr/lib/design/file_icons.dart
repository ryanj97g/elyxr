// What a file looks like in the browser. Elyxr is a file browser as much as
// anything else, so every entry gets classified into a FileKind and drawn by one
// widget — FileGlyph. Three places show entries (the TEXT row, the GRID tile and
// search results) and all three go through here, so the look of a file type is
// decided in exactly one file.
//
// Nothing here changes what's on screen yet: every kind still draws the same two
// terminal characters the browser has always used. What it does is put the seam
// in place — see kFileMarks for the one table an icon set replaces, a kind at a
// time, without a half-finished grid in between.

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'text.dart';

/// The categories a browser needs to tell apart at a glance. Deliberately about
/// what a file IS to someone looking for it, not about container formats: an
/// .m4a and an .mp3 are both [audio] even though only one can hide a video
/// track, because in a grid you're scanning for "my music", not for a codec.
enum FileKind {
  folder,
  audio,
  video,
  image,
  document, // pdf, doc, odt, rtf, epub…
  spreadsheet,
  presentation,
  archive,
  code,
  text, // plain notes, logs, readmes
  data, // json, xml, csv, sqlite, yaml
  font,
  disk, // iso, img, dmg
  app, // exe, apk, appimage, deb
  unknown,
}

/// Extension → kind. Lower-case, no leading dot. Anything absent is [unknown],
/// which is a real answer and not a failure — a browser shows plenty of files it
/// has no opinion about.
const Map<String, FileKind> kExtKinds = <String, FileKind>{
  // audio — mirrors kAudioExts in state/music.dart, plus formats the player
  // won't open but the browser still has to label
  'mp3': FileKind.audio, 'ogg': FileKind.audio, 'wav': FileKind.audio,
  'flac': FileKind.audio, 'm4a': FileKind.audio, 'aac': FileKind.audio,
  'opus': FileKind.audio, 'wma': FileKind.audio, 'aiff': FileKind.audio,
  'aif': FileKind.audio, 'mid': FileKind.audio, 'midi': FileKind.audio,
  'xm': FileKind.audio, 'mod': FileKind.audio, 's3m': FileKind.audio,
  'it': FileKind.audio,

  // video
  'mp4': FileKind.video, 'mkv': FileKind.video, 'avi': FileKind.video,
  'mov': FileKind.video, 'webm': FileKind.video, 'wmv': FileKind.video,
  'flv': FileKind.video, 'm4v': FileKind.video, 'mpg': FileKind.video,
  'mpeg': FileKind.video, '3gp': FileKind.video, 'm2ts': FileKind.video,

  // image
  'jpg': FileKind.image, 'jpeg': FileKind.image, 'png': FileKind.image,
  'gif': FileKind.image, 'bmp': FileKind.image, 'webp': FileKind.image,
  'tif': FileKind.image, 'tiff': FileKind.image, 'svg': FileKind.image,
  'heic': FileKind.image, 'heif': FileKind.image, 'avif': FileKind.image,
  'ico': FileKind.image, 'psd': FileKind.image, 'xcf': FileKind.image,
  'raw': FileKind.image, 'cr2': FileKind.image, 'nef': FileKind.image,
  'dng': FileKind.image,

  // document
  'pdf': FileKind.document, 'doc': FileKind.document, 'docx': FileKind.document,
  'odt': FileKind.document, 'rtf': FileKind.document, 'epub': FileKind.document,
  'mobi': FileKind.document, 'pages': FileKind.document,
  'tex': FileKind.document,

  // spreadsheet
  'xls': FileKind.spreadsheet, 'xlsx': FileKind.spreadsheet,
  'ods': FileKind.spreadsheet, 'numbers': FileKind.spreadsheet,
  'tsv': FileKind.spreadsheet,

  // presentation
  'ppt': FileKind.presentation, 'pptx': FileKind.presentation,
  'odp': FileKind.presentation, 'key': FileKind.presentation,

  // archive
  'zip': FileKind.archive, 'rar': FileKind.archive, '7z': FileKind.archive,
  'tar': FileKind.archive, 'gz': FileKind.archive, 'bz2': FileKind.archive,
  'xz': FileKind.archive, 'zst': FileKind.archive, 'tgz': FileKind.archive,
  'cab': FileKind.archive,

  // code
  'dart': FileKind.code, 'rs': FileKind.code, 'py': FileKind.code,
  'js': FileKind.code, 'jsx': FileKind.code,
  // '.ts' is TypeScript here. It's also MPEG transport stream, but one kind has
  // to win and a stray .ts video is rarer than a TypeScript file; '.m2ts' covers
  // the video case properly anyway.
  'ts': FileKind.code,
  'tsx': FileKind.code, 'c': FileKind.code, 'h': FileKind.code,
  'cpp': FileKind.code, 'hpp': FileKind.code, 'cc': FileKind.code,
  'cs': FileKind.code, 'java': FileKind.code, 'kt': FileKind.code,
  'go': FileKind.code, 'rb': FileKind.code, 'php': FileKind.code,
  'swift': FileKind.code, 'sh': FileKind.code, 'bash': FileKind.code,
  'zsh': FileKind.code, 'ps1': FileKind.code, 'bat': FileKind.code,
  'lua': FileKind.code, 'r': FileKind.code, 'pl': FileKind.code,
  'sql': FileKind.code, 'html': FileKind.code, 'css': FileKind.code,
  'scss': FileKind.code, 'vue': FileKind.code, 'svelte': FileKind.code,

  // text
  'txt': FileKind.text, 'md': FileKind.text, 'log': FileKind.text,
  'nfo': FileKind.text, 'diz': FileKind.text, 'srt': FileKind.text,
  'vtt': FileKind.text,

  // data
  'json': FileKind.data, 'xml': FileKind.data, 'csv': FileKind.data,
  'yaml': FileKind.data, 'yml': FileKind.data, 'toml': FileKind.data,
  'ini': FileKind.data, 'cfg': FileKind.data, 'conf': FileKind.data,
  'db': FileKind.data, 'sqlite': FileKind.data, 'parquet': FileKind.data,

  // font
  'ttf': FileKind.font, 'otf': FileKind.font, 'woff': FileKind.font,
  'woff2': FileKind.font, 'fnt': FileKind.font,

  // disk image
  'iso': FileKind.disk, 'img': FileKind.disk, 'dmg': FileKind.disk,
  'vhd': FileKind.disk, 'qcow2': FileKind.disk,

  // application
  'exe': FileKind.app, 'msi': FileKind.app, 'apk': FileKind.app,
  'appimage': FileKind.app, 'deb': FileKind.app, 'rpm': FileKind.app,
  'dll': FileKind.app, 'so': FileKind.app, 'jar': FileKind.app,
};

/// Classify an entry. [name] is the file name (extension is what decides it);
/// [mime] refines the answer when lymnal supplied one and the extension is
/// unfamiliar, so an extensionless file the server recognised still gets a kind.
FileKind fileKindOf(String name, {bool isDir = false, String? mime}) {
  if (isDir) return FileKind.folder;
  final dot = name.lastIndexOf('.');
  if (dot > 0 && dot < name.length - 1) {
    final hit = kExtKinds[name.substring(dot + 1).toLowerCase()];
    if (hit != null) return hit;
  }
  // No extension, or one we don't know: fall back to what the server said.
  final m = mime ?? '';
  if (m.startsWith('audio/')) return FileKind.audio;
  if (m.startsWith('video/')) return FileKind.video;
  if (m.startsWith('image/')) return FileKind.image;
  if (m.startsWith('font/')) return FileKind.font;
  if (m == 'application/pdf') return FileKind.document;
  if (m.startsWith('text/')) return FileKind.text;
  return FileKind.unknown;
}

/// What gets drawn for a kind: a character from the terminal's own vocabulary, an
/// SVG from the glyph set, or a glyph from an icon font. Three forms rather than
/// one so a set can land in pieces — see [kFileMarks].
class FileMark {
  /// A character the browser draws itself.
  final String? char;

  /// A glyph from an icon font (a .ttf declared in pubspec.yaml).
  final IconData? icon;

  /// An SVG at `assets/icons/filetype/<kind>.svg`. The path is derived from the
  /// kind rather than written out, so there's nothing to typo and nothing to keep
  /// in sync.
  final bool svg;

  const FileMark.char(String this.char)
      : icon = null,
        svg = false;
  const FileMark.icon(IconData this.icon)
      : char = null,
        svg = false;
  const FileMark.svg()
      : char = null,
        icon = null,
        svg = true;
}

// The block and the small square the browser has always drawn. Named, because
// they're the fallback every kind sits on until it has an icon of its own.
const FileMark _block = FileMark.char('█');
const FileMark _square = FileMark.char('▫');

/// THE SWAP POINT for a glyph icon set.
///
/// One line per kind. Replace a line's [FileMark.char] with [FileMark.svg] (for
/// `assets/icons/filetype/<kind>.svg`) or [FileMark.icon] (for an icon font) and
/// that kind switches over everywhere at once — text rows, grid tiles and search
/// results — while every other kind keeps the character it has now. So the set can
/// land a few kinds at a time and the grid never looks half-finished.
///
/// Either form inherits the palette colour and the terminal's size scaling from
/// [FileGlyph], so the set stays colour-agnostic and no call site ever moves. See
/// assets/icons/filetype/README.md for the drawing contract.
const Map<FileKind, FileMark> kFileMarks = <FileKind, FileMark>{
  FileKind.folder: _block,
  FileKind.audio: _square,
  FileKind.video: _square,
  FileKind.image: _square,
  FileKind.document: _square,
  FileKind.spreadsheet: _square,
  FileKind.presentation: _square,
  FileKind.archive: _square,
  FileKind.code: _square,
  FileKind.text: _square,
  FileKind.data: _square,
  FileKind.font: _square,
  FileKind.disk: _square,
  FileKind.app: _square,
  FileKind.unknown: _square,
};

/// The asset path holding a kind's SVG. Derived from the kind so there's no path
/// to typo, and public so a test can pin the exact string — this is one line of
/// string interpolation whose failure mode is a silent miss at runtime rather than
/// anything the compiler would catch.
String fileGlyphAsset(FileKind kind) => 'assets/icons/filetype/${kind.name}.svg';

/// Draw the mark for one entry. The only thing that renders a file's type, so
/// swapping characters for icons is invisible to every caller.
///
/// [size] is in the same units the surrounding [glass] text uses and gets the
/// same terminal scaling, so an icon lands optically the same size as the
/// character it replaced. [color] comes from the palette at the call site, which
/// is what keeps an icon set theme-driven rather than carrying its own colour.
class FileGlyph extends StatelessWidget {
  final FileKind kind;
  final double size;
  final Color color;

  const FileGlyph({
    super.key,
    required this.kind,
    required this.size,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final mark =
        kFileMarks[kind] ?? (kind == FileKind.folder ? _block : _square);
    // Scaled like the glass text it sits among, not raw pixels — otherwise a
    // glyph would ignore the terminal's own type scale and read undersized.
    final px = size * kGlassScale;
    final icon = mark.icon;
    if (icon != null) return Icon(icon, size: px, color: color);
    if (mark.svg) {
      return SvgPicture.asset(
        fileGlyphAsset(kind),
        width: px,
        height: px,
        // Repaints every visible pixel in the palette colour, so the artwork
        // carries no colour of its own — whatever it was exported with is
        // discarded and only the shape survives.
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
      );
    }
    return Text(mark.char!, style: glass(size, color));
  }
}
