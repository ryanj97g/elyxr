// The app root: provides the controllers, centres the fixed 440×884 chassis on
// the dark desk, and chooses between first run and the connected home from the
// session's link status.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'api/admin_client.dart';
import 'api/lymnal_client.dart';
import 'state/actions.dart';
import 'state/browse.dart';
import 'state/server.dart';
import 'state/session.dart';
import 'state/settings.dart';
import 'state/transfers.dart';
import 'state/trove_mount.dart';
import 'state/updater.dart';
import 'util/drag_out.dart';
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
        ChangeNotifierProvider(create: (_) => TroveMountController()),
        ChangeNotifierProvider(create: (_) => UpdateController(transfers)),
        Provider.value(value: FileActions(browse, transfers, settings)),
      ],
      child: MaterialApp(
        title: 'elyxr',
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
  LymnalClient? _dragClient;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final settings = context.watch<SettingsController>();
    final browse = context.read<BrowseController>();
    final server = context.read<ServerController>();

    // Keep the drag-out helper pointed at the live connection, so a file pulled
    // out of the window can be fetched and written to wherever it's dropped.
    if (_dragClient != session.client) {
      _dragClient = session.client;
      DragOut.useClient(session.client);
    }


    // Server mode connects to the local lymnal admin surface with the
    // machine-local admin token.
    if (settings.appMode == AppMode.server && !_serverTried) {
      _serverTried = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final dir = expandTilde('~/.local/share/lymnal');
        final token = await AdminClient.readToken(dir);
        final addr = await AdminClient.readAddress(dir) ?? session.serverAddress;
        if (token != null && addr != null) {
          server.connect(AdminClient(baseUrl: 'http://$addr', adminToken: token));
        }
        // Browse the trove straight off local disk in server mode — the files
        // are on this machine, so no token and no round-trip.
        final trovePath = await AdminClient.readTrovePath(dir);
        if (trovePath != null) {
          session.useLocalTrove(trovePath);
          browse.open('');
          browse.connectEvents();
        }
      });
    }
    if (settings.appMode == AppMode.client && _serverTried) {
      _serverTried = false;
      server.connect(null);
      session.useRemote();
    }

    // The trove mount (client only): the folder is live while the TROVE switch
    // is on and the link is up. trove is what actually mounts it; this starts
    // and stops that.
    final mount = context.read<TroveMountController>();
    final wantMount = settings.appMode == AppMode.client &&
        settings.trove &&
        session.status == LinkStatus.ok;
    if (wantMount && !mount.mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final token = session.bearerToken;
        final addr = session.serverAddress;
        if (token != null && addr != null) {
          await mount.mount(
            serverAddress: addr,
            token: token,
            mountPath: expandTilde(settings.mountPath),
          );
        }
      });
    } else if (!wantMount && mount.mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        mount.unmount(mountPath: expandTilde(settings.mountPath));
      });
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

    // In server mode this device manages its own lymnal (no client pairing
    // needed), so it goes straight to the connected home. Otherwise, no token
    // yet means first run.
    final child = settings.appMode == AppMode.server
        ? const HomeScreen()
        : (session.isFirstRun ? const FirstRunScreen() : const HomeScreen());

    // The window is transparent, so the metal fills it and its rounded corners
    // become the window's shape — no void, no chrome. FittedBox scales the fixed
    // 440×884 chassis to whatever size the window is, so it fits short screens.
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: FittedBox(fit: BoxFit.contain, child: child),
      ),
    );
  }
}
