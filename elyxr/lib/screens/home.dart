// The connected app: the chassis with its rails, swapping the tube between the
// files view and the settings screen. Holding the wordmark toggles the two
// (§ DESIGN Interactions); nothing else marks that path.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../design/chassis.dart';
import '../design/tokens.dart';
import '../state/session.dart';
import '../state/settings.dart';
import '../widgets/rails.dart';
import 'files_view.dart';
import 'settings_view.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _inSettings = false;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>();
    final session = context.watch<SessionController>();
    final p = settings.palette;

    // The trove is the main view on every device now — a client browses it over
    // the network, a server reads it straight off local disk. The server's own
    // controls (pairing, limits) live in Settings.
    Widget tubeChild;
    if (_inSettings) {
      tubeChild = const SettingsView();
    } else {
      tubeChild = const FilesView();
    }

    // Density is a global text scale for everything on the glass — the whole
    // terminal grows or tightens together. The metal rails sit outside this
    // MediaQuery, so the physical controls keep their fixed size.
    tubeChild = MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(settings.density.scale)),
      child: tubeChild,
    );

    return Chassis(
      palette: p,
      topRail: TopRail(
        palette: p,
        inSettings: _inSettings,
        onToggleSettings: () => setState(() => _inSettings = !_inSettings),
      ),
      tube: Tube(
        palette: p,
        child: tubeChild,
      ),
      bottomRail: BottomRail(
        palette: p,
        mode: settings.mode,
        status: session.status,
        onMode: (m) => settings.mode = m,
        inSettings: _inSettings,
      ),
    );
  }
}
