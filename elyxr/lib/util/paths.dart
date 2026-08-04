// Small local-path helpers shared by settings and transfers.

import 'dart:io';

/// Expand a leading `~` to the user's home directory.
String expandTilde(String p) {
  if (p == '~' || p.startsWith('~/')) {
    final home = Platform.environment['HOME'] ?? '';
    if (home.isNotEmpty) {
      return p == '~' ? home : '$home/${p.substring(2)}';
    }
  }
  return p;
}

/// Join a directory and a filename with the platform separator.
String joinPath(String dir, String name) {
  final sep = Platform.pathSeparator;
  return dir.endsWith(sep) ? '$dir$name' : '$dir$sep$name';
}
