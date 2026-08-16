import 'dart:io';

Future<int?> freeBytesOn(String path) async {
  if (!(Platform.isLinux || Platform.isMacOS)) return null;
  try {
    final r = await Process.run('df', ['-Pk', path]);
    if (r.exitCode != 0) return null;
    final lines = (r.stdout as String).trim().split('\n');
    if (lines.length < 2) return null;
    final cols = lines.last.trim().split(RegExp(r'\s+'));
    if (cols.length < 4) return null;
    final kb = int.tryParse(cols[3]);
    return kb == null ? null : kb * 1024;
  } catch (_) {
    return null;
  }
}
