// The settings screen, reached only by holding the wordmark. Replaces the files
// view inside the same tube, with the same scanlines and sweep. Numbered
// sections, an inverted accent header, and HOLD ELYXR TO EXIT in the footer.

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../design/text.dart';
import '../design/tokens.dart';
import '../state/session.dart';
import '../state/settings.dart';
import '../util/device.dart';
import 'server_view.dart';

class SettingsView extends StatelessWidget {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>();
    final session = context.watch<SessionController>();
    final p = settings.palette;

    return DefaultTextStyle(
      style: glass(20, p.bright, height: 1.32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Inverted header band.
          Container(
            color: p.a,
            padding: const EdgeInsets.fromLTRB(15, 9, 15, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('SETTINGS',
                    style: chassis(26, p.ink, weight: FontWeight.w700, spacing: 0.26)),
                const Spacer(),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('THIS DEVICE',
                        style: chassis(9, p.ink.withValues(alpha: 0.62), spacing: 0.16)),
                    Text(session.serverName ?? deviceName(),
                        style: mono(12, p.ink, weight: FontWeight.w600)),
                  ],
                ),
              ],
            ),
          ),
          Container(height: 2, color: p.dim),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(15, 13, 15, 0),
              children: [
                // On the server device, its controls (pairing, limits, recent
                // problems) live here in Settings, since the tube now shows the
                // trove's files like every other device.
                if (settings.appMode == AppMode.server) ...[
                  ServerControls(palette: p),
                  const SizedBox(height: 16),
                ],
                // A client can also surface the trove as a real folder in its
                // file manager (the optional gate mount) — Linux only, since the
                // gate is FUSE. Hidden where it can't run. Off by default.
                if (settings.appMode == AppMode.client && Platform.isLinux) ...[
                  _section(p, 'FS', 'USE SYSTEM FILE BROWSER', _GateRow(palette: p)),
                  const SizedBox(height: 13),
                ],
                _section(p, '01', 'ACCENT', _AccentPicker(palette: p)),
                const SizedBox(height: 13),
                _section(p, '02', 'DENSITY', _DensityPicker(palette: p)),
                const SizedBox(height: 13),
                _section(p, '03', 'TUBE', _TubePicker(palette: p)),
                const SizedBox(height: 13),
                _section(p, '04', 'CACHE', _CacheMeter(palette: p)),
                const SizedBox(height: 13),
                _section(p, '05', 'THIS DEVICE', _DeviceRows(palette: p)),
                const SizedBox(height: 13),
                _section(p, '06', 'PARTS', _Parts(palette: p)),
                const SizedBox(height: 16),
              ],
            ),
          ),
          Container(
            decoration: BoxDecoration(border: Border(top: BorderSide(color: p.dim))),
            padding: const EdgeInsets.fromLTRB(15, 9, 15, 11),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('ELYXR 1.0.0 · lymnal 1.0.0', style: mono(10, p.foot)),
                Text('HOLD ELYXR TO EXIT', style: chassis(10, p.mid, spacing: 0.1)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(Palette p, String num, String title, Widget body) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 9),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  color: p.a,
                  child: Text(num, style: mono(11, p.ink, weight: FontWeight.w600)),
                ),
                const SizedBox(width: 9),
                Text(title, style: chassis(12, p.bright, spacing: 0.16)),
                const SizedBox(width: 9),
                Expanded(
                  child: Container(
                    height: 1,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [p.dim, p.dim.withValues(alpha: 0)]),
                    ),
                  ),
                ),
              ],
            ),
          ),
          body,
        ],
      );
}

/// The "Use System File Browser" switch: turns the optional gate mount on and
/// off. Off means the trove lives in elyxr; on also surfaces it as a folder in
/// the file manager.
class _GateRow extends StatelessWidget {
  final Palette palette;
  const _GateRow({required this.palette});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsController>();
    final p = palette;
    final on = s.trove;
    return GestureDetector(
      onTap: () => s.trove = !on,
      behavior: HitTestBehavior.opaque,
      child: Row(
        children: [
          Expanded(
            child: Text(
              on
                  ? 'On — the trove also appears as a folder in your file manager, on the Desktop.'
                  : 'Off — the trove lives in elyxr. Turn this on to also open it as a folder in your file manager.',
              style: glass(15, p.mid),
            ),
          ),
          const SizedBox(width: 14),
          Container(
            width: 34,
            height: 18,
            padding: const EdgeInsets.symmetric(horizontal: 2),
            alignment: on ? Alignment.centerRight : Alignment.centerLeft,
            decoration: BoxDecoration(
              color: p.mv1,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Container(
              width: 13,
              height: 13,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: on ? p.a : p.mb,
                boxShadow: on ? [BoxShadow(color: p.a, blurRadius: 6)] : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AccentPicker extends StatelessWidget {
  final Palette palette;
  const _AccentPicker({required this.palette});

  @override
  Widget build(BuildContext context) {
    final settings = context.read<SettingsController>();
    return Row(
      children: [
        for (final accent in Accent.values)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 9),
              child: GestureDetector(
                onTap: () => settings.accent = accent,
                behavior: HitTestBehavior.opaque,
                child: _swatch(accent, accent == settings.accent, palette),
              ),
            ),
          ),
      ],
    );
  }

  /// Each swatch is a miniature tube in that colour, previewing the machine
  /// rather than showing a paint chip.
  Widget _swatch(Accent accent, bool on, Palette base) {
    final sp = Palette(accent, base.dark);
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(6, 8, 6, 7),
          decoration: BoxDecoration(
            color: base.dark ? const Color(0xFF030604) : const Color(0xFFf2f7f3),
            border: Border.all(color: on ? sp.a : base.dim),
            borderRadius: BorderRadius.circular(2),
            boxShadow: on ? [BoxShadow(color: sp.aAlpha(0.47), blurRadius: 15)] : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(height: 4, width: double.infinity, color: sp.a.withValues(alpha: on ? 1 : 0.4)),
              const SizedBox(height: 5),
              FractionallySizedBox(
                widthFactor: 0.46,
                alignment: Alignment.centerLeft,
                child: Container(height: 4, color: sp.a.withValues(alpha: on ? 0.55 : 0.22)),
              ),
              const SizedBox(height: 5),
              SizedBox(
                height: 10,
                child: Row(
                  children: List.generate(
                    8,
                    (i) => Expanded(
                      child: Container(
                        margin: const EdgeInsets.only(right: 1),
                        color: sp.a.withValues(alpha: i < 5 ? (on ? 0.95 : 0.4) : 0.13),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(accent.label, style: chassis(10, on ? base.bright : base.mid, spacing: 0.1)),
      ],
    );
  }
}

class _DensityPicker extends StatelessWidget {
  final Palette palette;
  const _DensityPicker({required this.palette});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final settings = context.read<SettingsController>();
    return Row(
      children: [
        for (final d in Density.values)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onTap: () => settings.density = d,
                behavior: HitTestBehavior.opaque,
                child: Column(
                  children: [
                    Container(
                      height: 48,
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: p.dark ? const Color(0xFF030604) : const Color(0xFFf2f7f3),
                        border: Border.all(color: d == settings.density ? p.a : p.dim),
                        borderRadius: BorderRadius.circular(2),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(
                          d == Density.tight ? 6 : (d == Density.mid ? 4 : 3),
                          (_) => Padding(
                            padding: EdgeInsets.symmetric(
                                vertical: d == Density.tight ? 1 : (d == Density.mid ? 2.5 : 4.5)),
                            child: Container(
                                height: 3,
                                color: (d == settings.density ? p.a : p.mid)
                                    .withValues(alpha: d == settings.density ? 0.9 : 0.5)),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(d.label,
                        style: chassis(10, d == settings.density ? p.bright : p.mid, spacing: 0.1)),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _TubePicker extends StatelessWidget {
  final Palette palette;
  const _TubePicker({required this.palette});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final settings = context.read<SettingsController>();
    Widget half(String label, String glyph, bool on, VoidCallback onTap) => Expanded(
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: onTap,
              behavior: HitTestBehavior.opaque,
              child: Column(
                children: [
                  Container(
                    height: 48,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: on
                          ? (p.dark ? const Color(0xFF030604) : const Color(0xFFf2f7f3))
                          : (p.dark ? const Color(0xFF0d1510) : const Color(0xFFd8e2da)),
                      border: Border.all(color: on ? p.a : p.dim),
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: Text(glyph,
                        style: glass(24, on ? p.a : p.foot).copyWith(
                            shadows: on ? [Shadow(color: p.a, blurRadius: 10)] : null)),
                  ),
                  const SizedBox(height: 6),
                  Text(label, style: chassis(10, on ? p.bright : p.mid, spacing: 0.1)),
                ],
              ),
            ),
          ),
        );
    return Row(
      children: [
        half('DARK', '●', settings.dark, () => settings.dark = true),
        half('LIGHT', '○', !settings.dark, () => settings.dark = false),
      ],
    );
  }
}

class _CacheMeter extends StatelessWidget {
  final Palette palette;
  const _CacheMeter({required this.palette});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final settings = context.watch<SettingsController>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 14,
          child: Row(
            children: List.generate(20, (i) {
              final lit = i < settings.cache;
              return Expanded(
                child: GestureDetector(
                  onTap: () => settings.cache = i + 1,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    margin: const EdgeInsets.only(right: 1),
                    color: lit ? p.a : p.dim,
                  ),
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 5),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('500 MB', style: chassis(10, p.mid, spacing: 0.1)),
            Text('${settings.cacheGb.toStringAsFixed(1)} GB',
                style: glass(27, p.bright)),
            Text('15 GB', style: chassis(10, p.mid, spacing: 0.1)),
          ],
        ),
      ],
    );
  }
}

/// The three programs the system is made of, each with its mark. It quietly
/// says what elyxr *is* — an app, a service, and a mount — rather than leaving
/// it abstract.
class _Parts extends StatelessWidget {
  final Palette palette;
  const _Parts({required this.palette});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    Widget part(String icon, String name, String role) => Expanded(
          child: Column(
            children: [
              Image.asset('assets/branding/$icon.png', width: 40, height: 40),
              const SizedBox(height: 6),
              Text(name, style: chassis(12, p.bright, spacing: 0.12)),
              Text(role, style: glass(13, p.foot)),
            ],
          ),
        );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        part('elyxr', 'elyxr', 'this app'),
        part('lymnal', 'lymnal', 'the service'),
        part('trove', 'trove', 'the mount'),
      ],
    );
  }
}

class _DeviceRows extends StatelessWidget {
  final Palette palette;
  const _DeviceRows({required this.palette});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final settings = context.watch<SettingsController>();
    final session = context.watch<SessionController>();

    Widget row(String label, Widget value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [Text(label, style: glass(20, p.mid)), value],
          ),
        );

    Widget check(bool on, VoidCallback onTap) => GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Text(on ? '▣' : '▢',
              style: glass(22, on ? p.bright : p.foot).copyWith(
                  shadows: on ? [Shadow(color: p.aAlpha(0.8), blurRadius: 9)] : null)),
        );

    return Column(
      children: [
        row(
          'MODE',
          GestureDetector(
            onTap: () => settings.appMode =
                settings.appMode == AppMode.server ? AppMode.client : AppMode.server,
            behavior: HitTestBehavior.opaque,
            child: Text('${settings.appMode.name.toUpperCase()}  ⇄', style: glass(20, p.a)),
          ),
        ),
        if (settings.appMode == AppMode.server)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text('Server controls are on the main screen (exit settings).',
                style: glass(14, p.foot)),
          ),
        row('DOWNLOADS', Text(settings.downloadDir, style: glass(20, p.bright))),
        row(
          'MOUNT AT',
          GestureDetector(
            onTap: () async {
              final v = await _editMountPath(context, p, settings.mountPath);
              if (v != null && v.trim().isNotEmpty) settings.mountPath = v.trim();
            },
            behavior: HitTestBehavior.opaque,
            child: Text('${settings.mountPath}  ✎', style: glass(20, p.a)),
          ),
        ),
        row('AT ONCE', Text('${settings.atOnce} transfers', style: glass(20, p.bright))),
        row('NOTIFY ON FINISH', check(settings.notify, () => settings.notify = !settings.notify)),
        row('TROVE FOLDER', check(settings.trove, () => settings.trove = !settings.trove)),
        if (session.serverName != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: GestureDetector(
              onTap: () => _confirmForget(context, session),
              behavior: HitTestBehavior.opaque,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('▸ FORGET ${session.serverName!.toUpperCase()}',
                    style: glass(19, const Color(0xFFf5b942))),
              ),
            ),
          ),
      ],
    );
  }

  Future<String?> _editMountPath(BuildContext context, Palette p, String current) {
    final ctrl = TextEditingController(text: current);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: p.tubeBg,
        title: Text('Mount the trove at', style: glass(18, p.bright)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: glass(18, p.bright),
          cursorColor: p.a,
          decoration: InputDecoration(hintText: '~/trove', hintStyle: glass(16, p.foot)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text('CANCEL', style: chassis(11, p.mid))),
          TextButton(onPressed: () => Navigator.pop(context, ctrl.text), child: Text('SET', style: chassis(11, p.a))),
        ],
      ),
    );
  }

  void _confirmForget(BuildContext context, SessionController session) {
    final p = palette;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: p.tubeBg,
        title: Text('Forget ${session.serverName}?', style: glass(20, p.bright)),
        content: Text(
          'This device will need to be approved again afterwards. Nothing in the trove is touched, and nothing changes on the server.',
          style: glass(16, p.soft),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('CANCEL', style: chassis(11, p.mid)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              session.forget();
            },
            child: Text('FORGET', style: chassis(11, p.a)),
          ),
        ],
      ),
    );
  }
}
