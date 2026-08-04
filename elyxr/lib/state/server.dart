// Server-mode state (§09). Present only in server mode. Talks to lymnal's local
// admin surface and holds the service status, pending requests, approved
// devices, space, and recent problems. Injectable admin client so it can be
// driven in tests.

import 'package:flutter/foundation.dart';

import '../api/admin_client.dart';
import '../api/api_error.dart';

class ServerController extends ChangeNotifier {
  AdminClient? _admin;

  ServerStatus? status;
  List<PendingRequest> pending = [];
  List<Device> devices = [];
  SpaceInfo? space;
  List<Problem> problems = [];
  String? error;
  bool loading = false;

  AdminClient? get admin => _admin;
  bool get available => _admin != null;

  /// Point at a running lymnal (server machine). Null clears server mode.
  void connect(AdminClient? admin) {
    _admin = admin;
    notifyListeners();
    if (admin != null) refresh();
  }

  Future<void> refresh() async {
    final a = _admin;
    if (a == null) return;
    loading = true;
    notifyListeners();
    try {
      status = await a.status();
      pending = await a.pending();
      devices = await a.devices();
      space = await a.space();
      problems = await a.problems();
      error = null;
    } on LymnalError catch (e) {
      error = e.message;
    } catch (e) {
      error = 'Could not reach the local service.';
    }
    loading = false;
    notifyListeners();
  }

  Future<void> setPairing(bool open) async {
    await _guard(() => _admin!.setPairing(open));
  }

  Future<void> approve(String device, {String role = 'owner', int? maxBytes}) async {
    await _guard(() => _admin!.approve(device, role: role, maxBytes: maxBytes));
  }

  Future<void> deny(String device) async {
    await _guard(() => _admin!.deny(device));
  }

  Future<void> revoke(String label) async {
    await _guard(() => _admin!.revoke(label));
  }

  Future<void> setLimits({int? maxBytes, int? warnAtBytes, int? warnEvery, int? minFreeBytes}) async {
    await _guard(() => _admin!.setLimits(
          maxBytes: maxBytes,
          warnAtBytes: warnAtBytes,
          warnEvery: warnEvery,
          minFreeBytes: minFreeBytes,
        ));
  }

  Future<void> recount() async {
    await _guard(() => _admin!.recount());
  }

  Future<void> _guard(Future<void> Function() action) async {
    if (_admin == null) return;
    try {
      await action();
      await refresh();
    } on LymnalError catch (e) {
      error = e.message;
      notifyListeners();
    }
  }
}
