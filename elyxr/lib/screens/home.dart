// The connected app: the chassis with its rails, swapping the tube between the
// files view and the settings screen. Holding the wordmark toggles the two
// (§ DESIGN Interactions); nothing else marks that path.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../design/chassis.dart';
import '../state/session.dart';
import '../state/settings.dart';
import '../state/updater.dart';
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
  int _peerSignal = 0;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>();
    final session = context.watch<SessionController>();
    final p = settings.palette;

    // On a client, when the server is on a newer build than this app, quietly
    // start a background update; the strip then tracks its progress and offers
    // the refresh when it's ready. appBuild is 0 on an un-stamped build, so this
    // never fires falsely.
    final updater = context.watch<UpdateController>();
    final serverBuild = session.health?.build ?? 0;
    if (settings.appMode == AppMode.client && appBuild > 0 && serverBuild > appBuild) {
      WidgetsBinding.instance.addPostFrameCallback((_) => updater.noticeBehind(serverBuild));
    }
    // The server announced it's updating (live, the instant it starts) — update
    // this device in step, right away, not on the next poll.
    if (settings.appMode == AppMode.client && session.peerUpdateSignal != _peerSignal) {
      _peerSignal = session.peerUpdateSignal;
      WidgetsBinding.instance.addPostFrameCallback((_) => updater.updateNow());
    }
    final showBanner = settings.appMode == AppMode.client &&
        !_inSettings &&
        updater.stage != UpdateStage.idle;

    Widget tubeChild;
    if (_inSettings) {
      tubeChild = const SettingsView();
    } else if (settings.appMode == AppMode.server) {
      tubeChild = ServerControls(palette: p);
    } else if (showBanner) {
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
