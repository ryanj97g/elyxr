// This device's own name, used when it introduces itself to a server at
// pairing time. It's the machine's short hostname, lowercased — so the server
// sees "probookrjg", not a value baked into the app.

import 'dart:io';

/// The short, lowercased hostname of this machine (everything before the first
/// dot). Falls back to a generic name if the host somehow has none.
String deviceName() {
  var h = Platform.localHostname;
  final dot = h.indexOf('.');
  if (dot > 0) h = h.substring(0, dot);
  h = h.trim().toLowerCase();
  return h.isEmpty ? 'elyxr-device' : h;
}
