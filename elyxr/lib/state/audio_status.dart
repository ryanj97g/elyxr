import 'package:flutter/foundation.dart';

/// A human-readable error if the SoLoud audio engine failed to start, or null
/// when audio is up. Set once at startup (see main.dart). The music player reads
/// it so a dead engine says *why* it's silent instead of the whole app just
/// quietly playing nothing — the buttons, the laugh, and the tracks all depend
/// on the engine, so this is the one place that explains a total silence.
final ValueNotifier<String?> audioError = ValueNotifier<String?>(null);
