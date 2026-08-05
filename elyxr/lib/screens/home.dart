// The connected app: the chassis with its rails, swapping the tube between the
// files view and the settings screen. Holding the wordmark toggles the two
// (§ DESIGN Interactions); nothing else marks that path.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../design/chassis.dart';
import '../state/session.dart';
import '../state/settings.dart';
import '../widgets/rails.dart';
import 'files_view.dart';
import 'server_view.dart';
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

    // Updates are driven by the lymnal background service now, so a client keeps
    // itself up to date with the app closed. The server's own "update now"
    // control and its progress live in the server view.
    Widget tubeChild;
    if (_inSettings) {
      tubeChild = const SettingsView();
    } else if (settings.appMode == AppMode.server) {
      tubeChild = ServerControls(palette: p);
    } else {
      tubeChild = const FilesView();
    }

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
        trove: settings.trove,
        status: session.status,
        onMode: (m) => settings.mode = m,
        onToggleTrove: () => settings.trove = !settings.trove,
      ),
    );
  }
}
