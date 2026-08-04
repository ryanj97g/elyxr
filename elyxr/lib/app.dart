// The app root: provides the controllers, centres the fixed 440×884 chassis on
// the dark desk, and chooses between first run and the connected home from the
// session's link status.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'api/admin_client.dart';
import 'state/actions.dart';
import 'state/browse.dart';
import 'state/server.dart';
import 'state/session.dart';
import 'state/settings.dart';
import 'state/transfers.dart';
import 'util/paths.dart';
import 'screens/first_run.dart';
import 'screens/home.dart';

class ElyxrApp extends StatelessWidget {
  final SettingsController settings;
  final SessionController session;
  final TransferController transfers;

  const ElyxrApp({
    super.key,
    required this.settings,
    required this.session,
    required this.transfers,
  });

  @override
  Widget build(BuildContext context) {
    final browse = BrowseController(session);
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: session),
        ChangeNotifierProvider.value(value: transfers),
        ChangeNotifierProvider.value(value: browse),
        ChangeNotifierProvider(create: (_) => ServerController()),
        Provider.value(value: FileActions(browse, transfers, settings)),
      ],
      child: MaterialApp(
        title: 'Elyxr',
        debugShowCheckedModeBanner: false,
        color: Colors.transparent,
        theme: ThemeData(
          useMaterial3: true,
          fontFamily: 'VT323',
          scaffoldBackgroundColor: Colors.transparent,
        ),
        home: const _Root(),
      ),
    );
  }
}

class _Root extends StatefulWidget {
  const _Root();

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  bool _openedOnce = false;
  bool _serverTried = false;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final settings = context.watch<SettingsController>();
    final browse = context.read<BrowseController>();
    final server = context.read<ServerController>();

    // Server mode connects to the local lymnal admin surface with the
    // machine-local admin token.
    if (settings.appMode == AppMode.server && !_serverTried) {
      _serverTried = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final token = await AdminClient.readToken(expandTilde('~/.local/share/lymnal'));
        final addr = session.serverAddress ?? kKnownServer;
        if (token != null) {
          server.connect(AdminClient(baseUrl: 'http://$addr', adminToken: token));
        }
      });
    }
    if (settings.appMode == AppMode.client && _serverTried) {
      _serverTried = false;
      server.connect(null);
    }

    // When a token is present and the link is up, open the trove once and start
    // listening for live changes.
    if (!session.isFirstRun && session.status == LinkStatus.ok && !_openedOnce) {
      _openedOnce = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        browse.open('');
        browse.connectEvents();
      });
    }
    if (session.isFirstRun) _openedOnce = false;

    final child = session.isFirstRun ? const FirstRunScreen() : const HomeScreen();

    // The window is exactly chassis-sized and transparent, so the metal fills
    // it and its rounded corners become the window's shape — no void, no chrome.
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: child,
    );
  }
}
