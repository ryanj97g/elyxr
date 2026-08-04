// The shapes lymnal returns (§04). Field names and types mirror the spec:
// sizes are bytes; times are Unix seconds; kind is "file" or "dir".

/// A warning that rides along on list/commit responses and the event stream —
/// approaching the limit. Not an error; shown once and dismissable.
class Warning {
  final String code;
  final String message;
  const Warning({required this.code, required this.message});

  factory Warning.fromJson(Map<String, dynamic> j) =>
      Warning(code: j['code'] as String, message: j['message'] as String);
}

/// One entry in a folder listing.
class Entry {
  final String name;
  final bool isDir;
  final int sizeBytes;
  final int mtime;
  final String? mime;
  final int? childCount;

  const Entry({
    required this.name,
    required this.isDir,
    required this.sizeBytes,
    required this.mtime,
    this.mime,
    this.childCount,
  });

  factory Entry.fromJson(Map<String, dynamic> j) => Entry(
        name: j['name'] as String,
        isDir: j['kind'] == 'dir',
        sizeBytes: (j['size_bytes'] as num?)?.toInt() ?? 0,
        mtime: (j['mtime'] as num?)?.toInt() ?? 0,
        mime: j['mime'] as String?,
        childCount: (j['child_count'] as num?)?.toInt(),
      );
}

/// A page of a folder listing, with the running total and any live warnings.
class ListPage {
  final String path;
  final List<Entry> entries;
  final String? nextCursor;
  final int usedBytes;
  final List<Warning> warnings;

  const ListPage({
    required this.path,
    required this.entries,
    required this.nextCursor,
    required this.usedBytes,
    required this.warnings,
  });

  factory ListPage.fromJson(Map<String, dynamic> j) => ListPage(
        path: j['path'] as String? ?? '',
        entries: (j['entries'] as List? ?? [])
            .map((e) => Entry.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
        nextCursor: j['next_cursor'] as String?,
        usedBytes: (j['used_bytes'] as num?)?.toInt() ?? 0,
        warnings: (j['warnings'] as List? ?? [])
            .map((w) => Warning.fromJson((w as Map).cast<String, dynamic>()))
            .toList(),
      );
}

/// The server's health, and the three facts the app keeps at hand.
class Health {
  final String version;
  final int uptimeS;
  final String trove;
  final int usedBytes;
  final int maxBytes;
  final int driveFreeBytes;
  final bool pairingOpen;

  const Health({
    required this.version,
    required this.uptimeS,
    required this.trove,
    required this.usedBytes,
    required this.maxBytes,
    required this.driveFreeBytes,
    required this.pairingOpen,
  });

  factory Health.fromJson(Map<String, dynamic> j) => Health(
        version: j['version'] as String? ?? '?',
        uptimeS: (j['uptime_s'] as num?)?.toInt() ?? 0,
        trove: j['trove'] as String? ?? 'Elyxr',
        usedBytes: (j['used_bytes'] as num?)?.toInt() ?? 0,
        maxBytes: (j['max_bytes'] as num?)?.toInt() ?? 0,
        driveFreeBytes: (j['drive_free_bytes'] as num?)?.toInt() ?? 0,
        pairingOpen: j['pairing_open'] as bool? ?? false,
      );
}

/// A search result: the entry and the folder it lives in.
class SearchHit {
  final String path;
  final bool isDir;
  final int sizeBytes;
  final int mtime;

  const SearchHit({
    required this.path,
    required this.isDir,
    required this.sizeBytes,
    required this.mtime,
  });

  factory SearchHit.fromJson(Map<String, dynamic> j) => SearchHit(
        path: j['path'] as String,
        isDir: j['kind'] == 'dir',
        sizeBytes: (j['size_bytes'] as num?)?.toInt() ?? 0,
        mtime: (j['mtime'] as num?)?.toInt() ?? 0,
      );

  String get folder {
    final i = path.lastIndexOf('/');
    return i < 0 ? '' : path.substring(0, i);
  }

  String get name {
    final i = path.lastIndexOf('/');
    return i < 0 ? path : path.substring(i + 1);
  }
}

/// Why a search walk was cut short, so a partial list is never shown as whole.
enum TruncateReason { limit, deadline }

class SearchResult {
  final List<SearchHit> results;
  final bool truncated;
  final TruncateReason? reason;

  const SearchResult({
    required this.results,
    required this.truncated,
    required this.reason,
  });

  factory SearchResult.fromJson(Map<String, dynamic> j) {
    final r = j['reason'] as String?;
    return SearchResult(
      results: (j['results'] as List? ?? [])
          .map((e) => SearchHit.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
      truncated: j['truncated'] as bool? ?? false,
      reason: r == 'limit'
          ? TruncateReason.limit
          : r == 'deadline'
              ? TruncateReason.deadline
              : null,
    );
  }
}

/// A same-name collision reported by resolve, before any transfer.
class Collision {
  final String name;
  final String kept;
  final List<String> skipped;

  const Collision({
    required this.name,
    required this.kept,
    required this.skipped,
  });

  factory Collision.fromJson(Map<String, dynamic> j) => Collision(
        name: j['name'] as String,
        kept: j['kept'] as String,
        skipped:
            (j['skipped'] as List? ?? []).map((e) => e as String).toList(),
      );
}

/// One flattened file in a resolved selection.
class ResolvedFile {
  final String path;
  final String name;
  final int sizeBytes;
  const ResolvedFile({required this.path, required this.name, required this.sizeBytes});

  factory ResolvedFile.fromJson(Map<String, dynamic> j) => ResolvedFile(
        path: j['path'] as String,
        name: j['name'] as String,
        sizeBytes: (j['size_bytes'] as num?)?.toInt() ?? 0,
      );
}

/// The real figures behind a selection, from POST /v1/resolve.
class ResolveResult {
  final int fileCount;
  final int totalBytes;
  final List<ResolvedFile> files;
  final List<Collision> collisions;

  /// "loose" (five or fewer, sent individually) or "zip" (one streamed zip).
  final String mode;

  const ResolveResult({
    required this.fileCount,
    required this.totalBytes,
    required this.files,
    required this.collisions,
    required this.mode,
  });

  bool get isZip => mode == 'zip';

  factory ResolveResult.fromJson(Map<String, dynamic> j) => ResolveResult(
        fileCount: (j['file_count'] as num?)?.toInt() ?? 0,
        totalBytes: (j['total_bytes'] as num?)?.toInt() ?? 0,
        files: (j['files'] as List? ?? [])
            .map((f) => ResolvedFile.fromJson((f as Map).cast<String, dynamic>()))
            .toList(),
        collisions: (j['collisions'] as List? ?? [])
            .map((c) => Collision.fromJson((c as Map).cast<String, dynamic>()))
            .toList(),
        mode: j['mode'] as String? ?? 'loose',
      );
}

/// The handle returned by upload/init: where to resume from and when it lapses.
class UploadSession {
  final String uploadId;
  final int chunkBytes;
  final int receivedBytes;
  final bool targetExists;
  final int expiresAt;

  const UploadSession({
    required this.uploadId,
    required this.chunkBytes,
    required this.receivedBytes,
    required this.targetExists,
    required this.expiresAt,
  });

  factory UploadSession.fromJson(Map<String, dynamic> j) => UploadSession(
        uploadId: j['upload_id'] as String,
        chunkBytes: (j['chunk_bytes'] as num?)?.toInt() ?? 8388608,
        receivedBytes: (j['received_bytes'] as num?)?.toInt() ?? 0,
        targetExists: j['target_exists'] as bool? ?? false,
        expiresAt: (j['expires_at'] as num?)?.toInt() ?? 0,
      );
}

/// One line off the change stream (§04 events). `event` is "change" or "usage".
class ServerEvent {
  final String event;
  final String? id;
  final Map<String, dynamic> data;
  const ServerEvent({required this.event, required this.id, required this.data});

  bool get isChange => event == 'change';
  bool get isUsage => event == 'usage';

  /// For a change event: "created" | "removed" | "modified".
  String? get changeKind => data['kind'] as String?;
  String? get changePath => data['path'] as String?;
}

/// A device discovered on the tailnet during first run.
class DiscoveredServer {
  final String name;
  final String address; // host:port
  final Health health;
  const DiscoveredServer(
      {required this.name, required this.address, required this.health});
}
