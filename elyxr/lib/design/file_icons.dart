// What a file looks like in the browser. Elyxr is a file browser as much as
// anything else, so every entry gets classified into a FileKind and drawn by one
// widget — FileGlyph. Three places show entries (the TEXT row, the GRID tile and
// search results) and all three go through here, so the look of a file type is
// decided in exactly one file.
//
// The drawn set lives in assets/icons/filetype/ — monochrome silhouettes, tinted
// from the palette at draw time, so they carry no colour of their own. Two lookup
// layers (see kExtGlyphs / kKindGlyphs): a file's own extension if an icon was
// drawn for it, otherwise the icon for its kind.

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
  // Trackers and chiptunes. The first four plus the wider libopenmpt bench are
  // all playable (kModuleExts in state/music.dart, guarded by a test that this
  // list doesn't drift from it); sid and nsf are here so they read as music in the
  // browser even though nothing decodes them yet.
  'xm': FileKind.audio, 'mod': FileKind.audio, 's3m': FileKind.audio,
  'it': FileKind.audio, '669': FileKind.audio, 'okt': FileKind.audio,
  'stm': FileKind.audio, 'med': FileKind.audio, 'mtm': FileKind.audio,
  'dbm': FileKind.audio, 'dmf': FileKind.audio, 'gdm': FileKind.audio,
  'imf': FileKind.audio, 'mdl': FileKind.audio, 'ptm': FileKind.audio,
  'ult': FileKind.audio, 'amf': FileKind.audio, 'far': FileKind.audio,
  'psm': FileKind.audio, 'j2b': FileKind.audio, 'mo3': FileKind.audio,
  'umx': FileKind.audio, 'mt2': FileKind.audio, 'dsm': FileKind.audio,
  'stx': FileKind.audio, 'nst': FileKind.audio, 'wow': FileKind.audio,
  'm15': FileKind.audio, 'mptm': FileKind.audio, 'ams': FileKind.audio,
  'dtm': FileKind.audio, 'plm': FileKind.audio, 'symmod': FileKind.audio,
  'stp': FileKind.audio, 'sid': FileKind.audio, 'nsf': FileKind.audio,
  'ahx': FileKind.audio,

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

// ---- the drawn set ----------------------------------------------------------
//
// The committed glyph set is finer-grained than FileKind in places: as well as one
// icon per kind there are icons for individual extensions (.JS, .MD, .PDF, and a
// deep bench of tracker/chiptune formats). So the lookup is two layers — the exact
// extension first, then the kind it belongs to — which means a .js gets the JS
// glyph while a .rb still gets the generic code glyph, with no gaps either way.

/// Extension → icon basename, for the icons drawn at finer grain than a kind.
/// Consulted BEFORE [kKindGlyphs]; anything absent falls through to its kind.
const Map<String, String> kExtGlyphs = <String, String>{
  // labelled by extension
  'js': 'js', 'json': 'json', 'html': 'html', 'css': 'css', 'svg': 'svg',
  'csv': 'csv', 'md': 'md', 'txt': 'txt', 'log': 'log', 'pdf': 'pdf',
  'rtf': 'rtf', 'doc': 'doc', 'docx': 'doc', 'gif': 'gif',
  // shells get the terminal glyph rather than the generic code one
  'sh': 'terminal', 'bash': 'terminal', 'zsh': 'terminal', 'ps1': 'terminal',
  'bat': 'terminal', 'cmd': 'terminal',
  // databases
  'db': 'database', 'sqlite': 'database', 'sqlite3': 'database',
  // certificates and calendars
  'pem': 'cert', 'crt': 'cert', 'cer': 'cert', 'der': 'cert', 'pfx': 'cert',
  'ics': 'calendar',
  // trackers and chiptunes — one glyph each, since telling them apart is most of
  // the point of having them
  'mod': 'mod', 'xm': 'xm', 's3m': 's3m', 'it': 'it', 'stm': 'stm',
  'okt': 'okt', 'med': 'med', '669': '669', 'ahx': 'ahx', 'sid': 'sid',
  'nsf': 'nsf',
};

/// Kind → icon basename. The fallback layer: everything lands here if the
/// extension has no glyph of its own.
///
/// A kind mapped to 'file' has no glyph drawn for it yet and borrows the generic
/// one — better than dropping back to a bare character now that a real set
/// exists. Give it its own name here once it's drawn.
const Map<FileKind, String> kKindGlyphs = <FileKind, String>{
  FileKind.folder: 'folder',
  FileKind.audio: 'audio',
  FileKind.video: 'video',
  FileKind.image: 'image',
  FileKind.document: 'file', // no generic document glyph yet
  FileKind.spreadsheet: 'spreadsheet',
  FileKind.presentation: 'file', // none drawn yet
  FileKind.archive: 'archive',
  FileKind.code: 'code',
  FileKind.text: 'file', // txt/md/log are labelled; the generic one isn't drawn
  FileKind.data: 'file',
  FileKind.font: 'font',
  FileKind.disk: 'disk',
  FileKind.app: 'app',
  FileKind.unknown: 'unknown',
};

/// The icon basename for an entry: its extension's own glyph if the set has one,
/// else its kind's. Never null — every kind has an entry, so there is always
/// something to draw.
String glyphNameFor(String name, {bool isDir = false, String? mime}) {
  if (!isDir) {
    final dot = name.lastIndexOf('.');
    if (dot > 0 && dot < name.length - 1) {
      final hit = kExtGlyphs[name.substring(dot + 1).toLowerCase()];
      if (hit != null) return hit;
    }
  }
  return kKindGlyphs[fileKindOf(name, isDir: isDir, mime: mime)] ?? 'unknown';
}

/// The asset path for an icon basename.
///
/// Public so a test can pin the exact string — this is one line of interpolation
/// whose failure mode is a silent miss at runtime rather than anything the
/// compiler would catch, and it has already shipped broken once.
String glyphAsset(String name) => 'assets/icons/filetype/$name.svg';

/// Draw the glyph for one entry. The only thing that renders a file's type, so the
/// row, the grid and search can never disagree about what a file looks like.
///
/// [size] is in the same units the surrounding [glass] text uses and gets the same
/// terminal scaling, so a glyph lands optically where its character did. [color]
/// comes from the palette at the call site: the artwork is repainted in it via
/// BlendMode.srcIn, so whatever colour the SVG was exported with never reaches the
/// screen and the set follows the theme like everything else.
class FileGlyph extends StatelessWidget {
  final String name;
  final bool isDir;
  final String? mime;
  final double size;
  final Color color;

  const FileGlyph({
    super.key,
    required this.name,
    required this.size,
    required this.color,
    this.isDir = false,
    this.mime,
  });

  @override
  Widget build(BuildContext context) {
    final px = size * kGlassScale;
    return SvgPicture.asset(
      glyphAsset(glyphNameFor(name, isDir: isDir, mime: mime)),
      width: px,
      height: px,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );
  }
}
