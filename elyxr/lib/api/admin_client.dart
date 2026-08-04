// Server mode's control plane (§09). lymnal has no interface of its own; on the
// server machine, Elyxr reaches lymnal's admin surface with the machine-local
// admin token (written by lymnal to data_dir/admin.token). These calls never
// leave the machine.

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'api_error.dart';

class ServerStatus {
  final bool running;
  final String version;
  final int uptimeS;
  final String bind;
  final String trove;
  final bool pairingOpen;
  ServerStatus.fromJson(Map<String, dynamic> j)
      : running = j['running'] as bool? ?? false,
        version = j['version'] as String? ?? '?',
        uptimeS = (j['uptime_s'] as num?)?.toInt() ?? 0,
        bind = j['bind'] as String? ?? '',
        trove = j['trove'] as String? ?? 'Elyxr',
        pairingOpen = j['pairing_open'] as bool? ?? false;
}

class PendingRequest {
  final String device;
  final String client;
  final String phrase;
  PendingRequest.fromJson(Map<String, dynamic> j)
      : device = j['device'] as String,
        client = j['client'] as String? ?? '',
        phrase = j['phrase'] as String? ?? '';
}

class Device {
  final String label;
  final String role;
  final int maxBytes;
  final int approvedAt;
  final int lastSeen;
  Device.fromJson(Map<String, dynamic> j)
      : label = j['label'] as String,
        role = j['role'] as String? ?? 'owner',
        maxBytes = (j['max_bytes'] as num?)?.toInt() ?? 0,
        approvedAt = (j['approved_at'] as num?)?.toInt() ?? 0,
        lastSeen = (j['last_seen'] as num?)?.toInt() ?? 0;
}

class SpaceInfo {
  final int usedBytes;
  final int driveFreeBytes;
  final int maxBytes;
  final int warnAtBytes;
  final int warnEvery;
  final int minFreeBytes;
  SpaceInfo.fromJson(Map<String, dynamic> j)
      : usedBytes = (j['used_bytes'] as num?)?.toInt() ?? 0,
        driveFreeBytes = (j['drive_free_bytes'] as num?)?.toInt() ?? 0,
        maxBytes = (j['max_bytes'] as num?)?.toInt() ?? 0,
        warnAtBytes = (j['warn_at_bytes'] as num?)?.toInt() ?? 0,
        warnEvery = (j['warn_every'] as num?)?.toInt() ?? 0,
        minFreeBytes = (j['min_free_bytes'] as num?)?.toInt() ?? 0;
}

class Problem {
  final int ts;
  final String method;
  final String path;
  final int status;
  final String? code;
  final String? message;
  Problem.fromJson(Map<String, dynamic> j)
      : ts = (j['ts'] as num?)?.toInt() ?? 0,
        method = j['method'] as String? ?? '',
        path = j['path'] as String? ?? '',
        status = (j['status'] as num?)?.toInt() ?? 0,
        code = j['code'] as String?,
        message = j['message'] as String?;
}

class AdminClient {
  final String baseUrl;
  final String adminToken;
  final http.Client _http;

  AdminClient({required this.baseUrl, required this.adminToken, http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  /// Read the local admin token lymnal wrote (data_dir/admin.token).
  static Future<String?> readToken(String dataDir) async {
    try {
      final f = File('$dataDir/admin.token');
      if (await f.exists()) return (await f.readAsString()).trim();
    } catch (_) {}
    return null;
  }

  Map<String, String> get _headers => {
        'X-Admin-Token': adminToken,
        'Content-Type': 'application/json',
      };

  Future<Map<String, dynamic>> _get(String path) async =>
      _decode(await _http.get(Uri.parse('$baseUrl$path'), headers: _headers));

  Future<Map<String, dynamic>> _post(String path, [Map<String, dynamic>? body]) async =>
      _decode(await _http.post(Uri.parse('$baseUrl$path'),
          headers: _headers, body: jsonEncode(body ?? {})));

  Map<String, dynamic> _decode(http.Response r) {
    if (r.statusCode >= 200 && r.statusCode < 300) {
      return r.body.isEmpty ? {} : (jsonDecode(r.body) as Map).cast<String, dynamic>();
    }
    Map<String, dynamic> body;
    try {
      body = (jsonDecode(r.body) as Map).cast<String, dynamic>();
    } catch (_) {
      body = {'code': 'IO_ERROR', 'message': 'Unreadable admin error.'};
    }
    throw LymnalError.fromJson(body, r.statusCode);
  }

  Future<ServerStatus> status() async => ServerStatus.fromJson(await _get('/v1/admin/status'));

  Future<void> setPairing(bool open) => _post('/v1/admin/pairing', {'open': open});

  Future<List<PendingRequest>> pending() async {
    final j = await _get('/v1/admin/pending');
    return (j['pending'] as List? ?? [])
        .map((e) => PendingRequest.fromJson((e as Map).cast()))
        .toList();
  }

  Future<void> approve(String device, {String role = 'owner', int? maxBytes}) =>
      _post('/v1/admin/approve', {
        'device': device,
        'role': role,
        if (maxBytes != null) 'max_bytes': maxBytes,
      });

  Future<void> deny(String device) => _post('/v1/admin/deny', {'device': device});

  Future<List<Device>> devices() async {
    final j = await _get('/v1/admin/devices');
    return (j['devices'] as List? ?? [])
        .map((e) => Device.fromJson((e as Map).cast()))
        .toList();
  }

  Future<void> revoke(String label) => _post('/v1/admin/revoke', {'label': label});

  Future<SpaceInfo> space() async => SpaceInfo.fromJson(await _get('/v1/admin/space'));

  Future<void> setLimits({int? maxBytes, int? warnAtBytes, int? warnEvery, int? minFreeBytes}) =>
      _post('/v1/admin/limits', {
        if (maxBytes != null) 'max_bytes': maxBytes,
        if (warnAtBytes != null) 'warn_at_bytes': warnAtBytes,
        if (warnEvery != null) 'warn_every': warnEvery,
        if (minFreeBytes != null) 'min_free_bytes': minFreeBytes,
      });

  Future<int> recount() async => (await _post('/v1/admin/recount'))['used_bytes'] as int? ?? 0;

  Future<List<Problem>> problems() async {
    final j = await _get('/v1/admin/problems');
    return (j['problems'] as List? ?? [])
        .map((e) => Problem.fromJson((e as Map).cast()))
        .toList();
  }
}
