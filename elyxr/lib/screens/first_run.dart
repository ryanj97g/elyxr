// First run (§08): elyxr opens with no token, finds the server on the tailnet
// by itself, you press Request Access, and it waits until someone at the server
// approves this device by name, then opens on the trove. Denied, timed out, and
// pairing-not-open are three different messages. Manual address entry is the
// only place an address is typed, and only when discovery fails.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_error.dart';
import '../api/models.dart';
import '../design/chassis.dart';
import '../design/text.dart';
import '../design/tokens.dart';
import '../state/session.dart';
import '../state/settings.dart';
import '../util/device.dart';
import '../widgets/rails.dart';

class FirstRunScreen extends StatefulWidget {
  const FirstRunScreen({super.key});

  @override
  State<FirstRunScreen> createState() => _FirstRunScreenState();
}

enum _Phase { discovering, chooseServer, noneFound, waiting, error }

class _FirstRunScreenState extends State<FirstRunScreen> {
  _Phase _phase = _Phase.discovering;
  List<DiscoveredServer> _servers = [];
  String? _errorMessage;
  final _addrCtrl = TextEditingController();
  final _deviceName = deviceName();

  @override
  void initState() {
    super.initState();
    _discover();
  }

  @override
  void dispose() {
    _addrCtrl.dispose();
    super.dispose();
  }

  Future<void> _discover({List<String> extra = const []}) async {
    setState(() => _phase = _Phase.discovering);
    final session = context.read<SessionController>();
    final found = await session.discover(extra: extra);
    if (!mounted) return;
    setState(() {
      _servers = found;
      _phase = found.isEmpty ? _Phase.noneFound : _Phase.chooseServer;
    });
  }

  Future<void> _request(String address) async {
    setState(() {
      _phase = _Phase.waiting;
    });
    final session = context.read<SessionController>();
    try {
      await session.requestAccess(address, deviceName: _deviceName);
      // On success the app root swaps to Home via the session listener.
    } on LymnalError catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _errorMessage = switch (e.code) {
          'PAIRING_CLOSED' =>
            "This server isn't accepting new devices yet. Ask someone at the server to open pairing, then try again.",
          'PAIRING_DENIED' =>
            'The request was declined at the server.',
          'PAIRING_TIMEOUT' =>
            'No one approved this device in time. Try again when someone is at the server.',
          _ => e.message,
        };
      });
    } on ConnectionError catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _errorMessage = e.message();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>();
    final p = settings.palette;
    return Chassis(
      palette: p,
      topRail: TopRail(palette: p, inSettings: false, onToggleSettings: () {}),
      tube: Tube(palette: p, child: _body(p)),
      bottomRail: _railStub(p),
    );
  }

  Widget _railStub(Palette p) => Padding(
        padding: const EdgeInsets.fromLTRB(3, 1, 3, 2),
        child: Row(
          children: [
            Text('NOT PAIRED', style: chassis(9, p.mt, spacing: 0.1)),
            const Spacer(),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(shape: BoxShape.circle, color: p.mt),
            ),
          ],
        ),
      );

  Widget _body(Palette p) {
    return DefaultTextStyle(
      style: glass(18, p.bright),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          children: [
            Expanded(
              child: switch (_phase) {
                _Phase.discovering => _centered(p, 'LOOKING FOR A SERVER ON THE TAILNET…'),
                _Phase.chooseServer => _chooseServer(p),
                _Phase.noneFound => _noneFound(p),
                _Phase.waiting => _waiting(p),
                _Phase.error => _error(p),
              },
            ),
            // This device can be the server instead of a client — the way out
            // of the first-run screen when it's the machine holding the files.
            if (_phase != _Phase.waiting)
              GestureDetector(
                onTap: () =>
                    context.read<SettingsController>().appMode = AppMode.server,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text('THIS DEVICE IS THE SERVER ▸',
                      style: chassis(10, p.mid, spacing: 0.1)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _centered(Palette p, String text) => Center(
        child: Text(text, textAlign: TextAlign.center, style: glass(17, p.mid)),
      );

  Widget _chooseServer(Palette p) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('SERVERS FOUND', style: chassis(12, p.bright, spacing: 0.16)),
          const SizedBox(height: 12),
          for (final s in _servers)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GestureDetector(
                onTap: () => _request(s.address),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(border: Border.all(color: p.dim)),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(s.name, style: glass(18, p.bright)),
                            Text(s.address, style: glass(13, p.foot)),
                          ],
                        ),
                      ),
                      Text('REQUEST ACCESS ▸', style: chassis(10, p.a, spacing: 0.1)),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: 4),
          GestureDetector(
            onTap: () => _discover(),
            child: Text('↻ LOOK AGAIN', style: chassis(10, p.mid, spacing: 0.1)),
          ),
        ],
      );

  Widget _noneFound(Palette p) => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text("Couldn't find a server on the tailnet.",
              style: glass(18, p.bright)),
          const SizedBox(height: 6),
          Text('Enter its address by hand.', style: glass(15, p.mid)),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(border: Border.all(color: p.dim)),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _addrCtrl,
                    style: glass(16, p.bright),
                    cursorColor: p.a,
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: '100.x.x.x:7749',
                      hintStyle: glass(16, p.foot),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () {
              final a = _addrCtrl.text.trim();
              if (a.isNotEmpty) _discover(extra: [a]);
            },
            child: Text('CONNECT ▸', style: chassis(11, p.a, spacing: 0.1)),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () => _discover(),
            child: Text('↻ LOOK AGAIN', style: chassis(10, p.mid, spacing: 0.1)),
          ),
        ],
      );

  Widget _waiting(Palette p) => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('WAITING FOR APPROVAL', style: chassis(12, p.mid, spacing: 0.16)),
          const SizedBox(height: 16),
          Text('Approve this device on the server, where it appears as '
              '"$_deviceName".', style: glass(16, p.soft)),
          const SizedBox(height: 18),
          Center(child: Text('…', style: glass(24, p.mid))),
        ],
      );

  Widget _error(Palette p) => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_errorMessage ?? 'Something went wrong.',
              style: glass(18, p.bright)),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: () => _discover(),
            child: Text('◂ START OVER', style: chassis(11, p.a, spacing: 0.1)),
          ),
        ],
      );
}
