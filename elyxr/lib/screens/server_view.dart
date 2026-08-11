// The Server controls, shown inside the tube when this device is in server
// mode. lymnal needs no interface of its own; this manages the local service:
// service state, pending requests and approved devices, trove space limits, and
// recent problems. It talks to lymnal's local admin surface (connected by the
// app root).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/admin_client.dart';
import '../design/text.dart';
import '../design/tokens.dart';
import '../state/server.dart';
import '../util/format.dart';
import '../widgets/update_sheet.dart';

class ServerControls extends StatefulWidget {
  final Palette palette;
  const ServerControls({super.key, required this.palette});

  @override
  State<ServerControls> createState() => _ServerControlsState();
}

class _ServerControlsState extends State<ServerControls> {
  // While the panel is open and pairing is on, poll for new requests so one
  // that arrives after you opened the panel shows up on its own; without this
  // you'd have to close and reopen the panel to see it.
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    // Refresh once shown; the admin client is connected by the app root.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<ServerController>().refresh();
    });
    _poll = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted) return;
      final s = context.read<ServerController>();
      // Only poll when there's something to catch: pairing is open. Closed,
      // no new request can arrive, so we stay quiet.
      if (s.available && (s.status?.pairingOpen ?? false)) s.pollPending();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final server = context.watch<ServerController>();
    // Shrink-wraps so it can sit inside the settings scroll view (which owns the
    // scrolling); no Expanded/ListView of its own.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: p.a,
          padding: const EdgeInsets.fromLTRB(15, 10, 12, 10),
          child: Row(
            children: [
              Text('SERVER',
                  style: chassis(22, p.ink, weight: FontWeight.w700, spacing: 0.2)),
              const Spacer(),
              _action(Text('↻', style: glass(22, p.ink)),
                  () => server.refresh()),
            ],
          ),
        ),
        UpdateBanner(p: p),
        if (!server.available)
          Padding(
            padding: const EdgeInsets.all(14),
            child: Text('Connecting to the local service…', style: glass(15, p.mid)),
          ),
        if (server.error != null)
          Container(
            width: double.infinity,
            color: const Color(0xFF2e2f18),
            padding: const EdgeInsets.all(8),
            child: Text(server.error!, style: glass(14, const Color(0xFFf5b942))),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 12, 0, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _service(p, server),
              const SizedBox(height: 16),
              _pairing(context, p, server),
              const SizedBox(height: 16),
              _devices(context, p, server),
              const SizedBox(height: 16),
              _space(context, p, server),
              const SizedBox(height: 16),
              _problems(p, server),
            ],
          ),
        ),
      ],
    );
  }

  Widget _head(Palette p, String t) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(t, style: chassis(12, p.bright, spacing: 0.16)),
      );

  Widget _row(Palette p, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(k, style: glass(16, p.mid)),
          Text(v, style: glass(16, p.bright)),
        ]),
      );

  Widget _service(Palette p, ServerController s) {
    final st = s.status;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // Update lives in Settings › THIS DEVICE now (one control, every mode), so
      // the SERVICE panel just reports state — no button of its own.
      Row(children: [
        Image.asset('assets/branding/lymnal.png', width: 22, height: 22),
        const SizedBox(width: 7),
        Text('SERVICE', style: chassis(12, p.bright, spacing: 0.16)),
      ]),
      const SizedBox(height: 6),
      _row(p, 'STATE', st == null ? '—' : (st.running ? 'RUNNING' : 'STOPPED')),
      if (st != null) ...[
        _row(p, 'VERSION', '${st.version} · build ${st.build}'),
        _row(p, 'UPTIME', _uptime(st.uptimeS)),
        _row(p, 'ADDRESS', st.bind),
      ],
    ]);
  }

  Widget _pairing(BuildContext context, Palette p, ServerController s) {
    final open = s.status?.pairingOpen ?? false;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text('PAIRING', style: chassis(12, p.bright, spacing: 0.16)),
        _action(
          Text(
              s.busy
                  ? 'WORKING…'
                  : (open ? 'ON — CLOSE' : 'OFF — OPEN'),
              style: chassis(11, s.busy ? p.mid : p.a, spacing: 0.1)),
          s.busy ? () {} : () => s.setPairing(!open),
        ),
      ]),
      const SizedBox(height: 6),
      if (s.pending.isEmpty)
        Text(open ? 'Waiting for a device to ask…' : 'Open pairing to approve a new device.',
            style: glass(15, p.mid))
      else
        for (final req in s.pending) _pendingCard(context, p, s, req),
    ]);
  }

  Widget _pendingCard(BuildContext context, Palette p, ServerController s, PendingRequest req) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(border: Border.all(color: p.a)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('"${req.device}" wants access', style: glass(17, p.bright)),
        const SizedBox(height: 2),
        Text('Approve it only if you recognise this device.', style: glass(13, p.foot)),
        const SizedBox(height: 8),
        Row(children: [
          _action(
              Text('APPROVE (OWNER)', style: chassis(11, p.a, spacing: 0.1)),
              () => s.approve(req.device)),
          _action(
              Text('AS GUEST', style: chassis(11, p.mid, spacing: 0.1)),
              () => s.approve(req.device,
                  role: 'guest', maxBytes: 10000000000)),
          const Spacer(),
          _action(Text('DENY', style: chassis(11, p.mid, spacing: 0.1)),
              () => s.deny(req.device)),
        ]),
      ]),
    );
  }

  Widget _devices(BuildContext context, Palette p, ServerController s) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _head(p, 'DEVICES'),
      if (s.devices.isEmpty) Text('No devices approved yet.', style: glass(15, p.mid)),
      for (final d in s.devices)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(d.label, style: glass(16, p.bright)),
                Text('${d.role} · ${fmtGb(d.maxBytes)}G${d.lastSeen > 0 ? ' · seen ${_ago(d.lastSeen)}' : ''}',
                    style: glass(12, p.foot)),
              ]),
            ),
            _action(Text('REVOKE', style: chassis(10, p.mid, spacing: 0.1)),
                () => s.revoke(d.label)),
          ]),
        ),
    ]);
  }

  Widget _space(BuildContext context, Palette p, ServerController s) {
    final sp = s.space;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text('SPACE', style: chassis(12, p.bright, spacing: 0.16)),
        _action(Text('RECOUNT', style: chassis(10, p.a, spacing: 0.1)),
            () => s.recount()),
      ]),
      const SizedBox(height: 6),
      if (sp != null) ...[
        _row(p, 'USED', '${fmtGb(sp.usedBytes)}G of ${fmtGb(sp.maxBytes)}G'),
        _row(p, 'DRIVE FREE', '${fmtGb(sp.driveFreeBytes)}G'),
        _editRow(context, p, s, 'TROVE LIMIT', sp.maxBytes, (v) => s.setLimits(maxBytes: v)),
        _editRow(context, p, s, 'WARN AT', sp.warnAtBytes, (v) => s.setLimits(warnAtBytes: v)),
        _editRow(context, p, s, 'KEEP DRIVE CLEAR', sp.minFreeBytes, (v) => s.setLimits(minFreeBytes: v)),
      ],
    ]);
  }

  Widget _editRow(BuildContext context, Palette p, ServerController s, String label, int bytes,
      void Function(int) apply) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(label, style: glass(16, p.mid)),
        _action(
          Text('${fmtGb(bytes)}G  ✎', style: glass(16, p.bright)),
          () async {
            final v = await _editGb(context, p, label, bytes);
            if (v != null) apply(v);
          },
        ),
      ]),
    );
  }

  Future<int?> _editGb(BuildContext context, Palette p, String label, int bytes) async {
    final ctrl = TextEditingController(text: fmtGb(bytes));
    final v = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: p.tubeBg,
        title: Text(label, style: glass(18, p.bright)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          style: glass(18, p.bright),
          cursorColor: p.a,
          decoration: InputDecoration(suffixText: 'GB', suffixStyle: glass(16, p.mid)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text('CANCEL', style: chassis(11, p.mid))),
          TextButton(onPressed: () => Navigator.pop(context, ctrl.text), child: Text('SET', style: chassis(11, p.a))),
        ],
      ),
    );
    if (v == null) return null;
    final gb = double.tryParse(v.trim());
    if (gb == null) return null;
    return (gb * 1e9).round();
  }

  Widget _problems(Palette p, ServerController s) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _head(p, 'RECENT PROBLEMS'),
      if (s.problems.isEmpty) Text('Nothing has gone wrong.', style: glass(15, p.mid)),
      for (final pr in s.problems)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Text(
            pr.message ?? '${pr.method} ${pr.path} → ${pr.status}',
            style: glass(14, p.soft),
          ),
        ),
    ]);
  }

  String _uptime(int s) {
    final d = s ~/ 86400, h = (s % 86400) ~/ 3600;
    return d > 0 ? '${d}d ${h}h' : '${h}h ${(s % 3600) ~/ 60}m';
  }

  String _ago(int ts) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final d = now - ts;
    if (d < 60) return 'just now';
    if (d < 3600) return '${d ~/ 60}m ago';
    if (d < 86400) return '${d ~/ 3600}h ago';
    return '${d ~/ 86400}d ago';
  }
}

/// A tappable label with a real target around it.
///
/// Every action on this screen used to be a bare GestureDetector wrapped straight
/// round a Text. A GestureDetector with a child defaults to
/// HitTestBehavior.deferToChild, so the only thing that could be hit was the
/// glyph box itself — an 11px strip of small caps, with no padding and no slack.
/// On a scaled display that is close to unclickable, and the pairing toggle in
/// particular reads as a dead control.
///
/// Opaque, so the padding counts as part of the button rather than as a hole in
/// it.
Widget _action(Widget label, VoidCallback onTap) => GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: label,
      ),
    );
