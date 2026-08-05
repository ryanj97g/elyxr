// Failures, in two families (§09, §11 of the specs).
//
// A [LymnalError] is one lymnal reported: its `message` is written for a person
// and is shown WORD FOR WORD, never reworded or summarised. `code` and
// `requestId` sit behind a details toggle.
//
// A [ConnectionError] is one lymnal could not report, because the request never
// arrived — the three states that belong to elyxr.

/// An error lymnal returned, in the one shape every endpoint uses.
class LymnalError implements Exception {
  final String code;
  final String message;
  final Map<String, dynamic>? detail;
  final String? hint;
  final String? requestId;
  final int httpStatus;

  const LymnalError({
    required this.code,
    required this.message,
    required this.httpStatus,
    this.detail,
    this.hint,
    this.requestId,
  });

  factory LymnalError.fromJson(Map<String, dynamic> json, int status) {
    return LymnalError(
      code: json['code'] as String? ?? 'IO_ERROR',
      // If a body somehow lacks a message, say so plainly rather than blank.
      message: json['message'] as String? ??
          'Something went wrong, and the server did not say what.',
      httpStatus: status,
      detail: (json['detail'] as Map?)?.cast<String, dynamic>(),
      hint: json['hint'] as String?,
      requestId: json['request_id'] as String?,
    );
  }

  /// True when this device is no longer approved (401). The app offers to ask
  /// for access again.
  bool get isNoLongerApproved =>
      httpStatus == 401 && (code == 'BAD_TOKEN' || code == 'TOKEN_REVOKED');

  @override
  String toString() => 'LymnalError($code): $message';
}

/// Why a request never reached the server. Each has its own message and its own
/// next step (§11 of the elyxr spec).
enum ConnectionFault {
  /// "Can't reach ryang5mini. It may be asleep or off." Retry every few seconds.
  unreachable,

  /// "Tailscale isn't connected on this device." Distinct from asleep.
  noTailnet,

  /// "This device is no longer approved." Offer to request access again.
  notApproved,
}

class ConnectionError implements Exception {
  final ConnectionFault fault;

  /// The server's name, when known, so the message can name it.
  final String? serverName;

  const ConnectionError(this.fault, {this.serverName});

  String message() {
    switch (fault) {
      case ConnectionFault.unreachable:
        final name = serverName ?? 'the server';
        return "Can't reach $name. It may be asleep or off.";
      case ConnectionFault.noTailnet:
        return "Tailscale isn't connected on this device.";
      case ConnectionFault.notApproved:
        return 'This device is no longer approved.';
    }
  }

  @override
  String toString() => 'ConnectionError(${fault.name})';
}
