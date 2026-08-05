// Orchestrates the two transfer flows so the UI stays thin: a download resolves
// first (so the mode and any skipped duplicates can be stated before anything
// moves, §05), and an upload turns dropped or chosen files — folders kept whole
// — into queued transfers.

import 'dart:io';

import '../api/models.dart';
import '../util/paths.dart';
import 'browse.dart';
import 'settings.dart';
import 'transfers.dart';

class FileActions {
  final BrowseController browse;
  final TransferController transfers;
  final SettingsController settings;

  FileActions(this.browse, this.transfers, this.settings);

  /// Resolve a selection to its real figures and mode, before any transfer.
  Future<ResolveResult?> resolve(List<String> paths) async {
    final client = browse.session.client;
    if (client == null) return null;
    return client.resolve(paths);
  }

  /// Start a download from an already-resolved selection. Five or fewer files
  /// land loose, three at a time; more than five arrive as one zip.
  void startDownload(List<String> paths, ResolveResult res) {
    final dir = expandTilde(settings.downloadDir);
    if (res.isZip) {
      final name = _zipName(paths);
      transfers.enqueueZip(
        zipPaths: paths,
        localPath: joinPath(dir, name),
        name: name,
      );
    } else {
      for (final f in res.files) {
        transfers.enqueueDownload(
          remotePath: f.path,
          localPath: joinPath(dir, f.name),
          name: f.name,
          totalBytes: f.sizeBytes,
        );
      }
    }
  }

  /// Queue uploads for a set of local paths into [folder] (defaults to the
  /// current folder). Directories are walked so their structure is kept.
  Future<void> uploadPaths(List<String> localPaths, {String? folder}) async {
    final base = folder ?? browse.path;
    for (final local in localPaths) {
      final type = FileSystemEntity.typeSync(local);
      if (type == FileSystemEntityType.directory) {
        final root = Directory(local);
        final rootName = _basename(local);
        await for (final entity in root.list(recursive: true, followLinks: false)) {
          if (entity is File) {
            final rel = entity.path.substring(root.path.length + 1).replaceAll('\\', '/');
            final remote = _join(base, '$rootName/$rel');
            transfers.enqueueUpload(
              localPath: entity.path,
              remotePath: remote,
              name: _basename(entity.path),
            );
          }
        }
      } else if (type == FileSystemEntityType.file) {
        final name = _basename(local);
        transfers.enqueueUpload(
          localPath: local,
          remotePath: _join(base, name),
          name: name,
        );
      }
    }
  }

  String _join(String base, String rest) => base.isEmpty ? rest : '$base/$rest';

  String _basename(String path) {
    final norm = path.replaceAll('\\', '/');
    final i = norm.lastIndexOf('/');
    return i < 0 ? norm : norm.substring(i + 1);
  }

  /// Name a zip after the single selected folder, or the current folder.
  String _zipName(List<String> paths) {
    if (paths.length == 1) return '${_basename(paths.first)}.zip';
    final here = browse.path.isEmpty ? 'elyxr' : _basename(browse.path);
    return '$here.zip';
  }
}
