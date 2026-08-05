// Dragging a file out of the elyxr window onto the desktop (or any folder). The
// window can't start an operating-system drag by itself — Flutter doesn't offer
// that on Linux — so a small piece of native code in the runner does the drag,
// and this is the Dart side that talks to it.
//
// The exchange has no middleman file on the client:
//   1. You start dragging a row  → begin(path, name) tells the native side which
//      server file this drag carries.
//   2. You drop somewhere         → the native side learns the exact drop path
//      and calls back here.
//   3. writeTo downloads that file straight to the drop path, streaming the
//      bytes from the server to that spot — nothing is staged in between.

import 'dart:io';

import 'package:flutter/services.dart';

import '../api/lymnal_client.dart';

class DragOut {
  static const _ch = MethodChannel('elyxr/dragout');
  static LymnalClient? _client;

  /// Hand it the connected client (and re-hand it on reconnect) so a drop can
  /// fetch the file. Also wires the callback the native side uses on drop.
  static void useClient(LymnalClient? client) {
    _client = client;
    _ch.setMethodCallHandler(_onNativeCall);
  }

  /// Begin dragging the server file at [path] (shown as [name]) out of the
  /// window. A no-op off Linux, and harmless if the native side isn't present.
  static Future<void> begin(String path, String name) async {
    if (!Platform.isLinux) return;
    try {
      await _ch.invokeMethod('beginDrag', {'path': path, 'name': name});
    } catch (_) {
      // No native drag support present — nothing to do.
    }
  }

  static Future<Object?> _onNativeCall(MethodCall call) async {
    if (call.method == 'writeTo') {
      final args = (call.arguments as Map).cast<String, dynamic>();
      return _writeTo(args['path'] as String, args['dest'] as String);
    }
    return null;
  }

  /// Download the server file to the exact local path the drop chose. Returns
  /// true on success so the native side can report the drop finished; on failure
  /// it removes the half-written file so nothing broken is left behind.
  static Future<bool> _writeTo(String serverPath, String dest) async {
    final client = _client;
    if (client == null) return false;
    final file = File(dest);
    final sink = file.openWrite();
    try {
      await client.downloadTo(serverPath, sink);
      await sink.flush();
      await sink.close();
      return true;
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      try {
        await file.delete();
      } catch (_) {}
      return false;
    }
  }
}
