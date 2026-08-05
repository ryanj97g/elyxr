// The connected app: the chassis with its rails, swapping the tube between the
// files view and the settings screen. Holding the wordmark toggles the two
// (§ DESIGN Interactions); nothing else marks that path.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../design/chassis.dart';
import '../state/session.dart';
import '../state/settings.dart';
import '../util/build_info.dart';
import '../widgets/rails.dart';
import '../widgets/update_sheet.dart';
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

    // On a client, offer an update when the server is on a newer build than
    // this app was built at. appBuild is 0 on an un-stamped build, so this never
    // fires falsely.
    final serverBuild = session.health?.build ?? 0;
    final updateReady = settings.appMode == AppMode.client &&
        !_inSettings &&
        appBuild > 0 &&
        serverBuild > appBuild;

    Widget tubeChild;
    if (_inSettings) {
      tubeChild = const SettingsView();
    } else if (settings.appMode == AppMode.server) {
      tubeChild = ServerControls(palette: p);
    } else if (updateReady) {
      tubeChild = Column(children: [
        UpdateBanner(p: p),
        const Expanded(child: FilesView()),
      ]);
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
