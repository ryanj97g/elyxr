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
          // Terminal header: a phosphor title with an accent caret and a dim
          // underline — the same restrained console vocabulary as the files
          // view, not an inverted slab.
          Container(
            padding: const EdgeInsets.fromLTRB(13, 11, 13, 10),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: p.dim)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('▸',
                    style: glass(23, p.a).copyWith(
                        shadows: [Shadow(color: p.a, blurRadius: 10)])),
                const SizedBox(width: 8),
                Text('SETTINGS',
                    style: glass(26, p.bright).copyWith(
                        shadows: [Shadow(color: p.aAlpha(0.7), blurRadius: 9)])),
                const Spacer(),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('THIS DEVICE', style: glass(13, p.mid)),
                    Text(session.serverName ?? deviceName(),
                        style: mono(12, p.bright, weight: FontWeight.w600)),
                  ],
                ),
              ],
            ),
          ),
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
                _section(p, '01', 'ACCENT', _AccentPicker(palette: p)),
                const SizedBox(height: 13),
                _section(p, '02', 'DENSITY', _DensityPicker(palette: p)),
                const SizedBox(height: 13),
                _section(p, '03', 'TYPEFACE', _FacePicker(palette: p)),
                const SizedBox(height: 13),
                _section(p, '04', 'TUBE', _TubePicker(palette: p)),
                const SizedBox(height: 13),
                _section(p, '05', 'THIS DEVICE', _DeviceRows(palette: p)),
                // A client can surface the trove as a real folder (the optional
                // gate mount) — Linux only, off by default. Kept last.
                if (settings.appMode == AppMode.client && Platform.isLinux) ...[
                  const SizedBox(height: 13),
                  _section(p, '06', 'USE SYSTEM FILE BROWSER', _GateRow(palette: p)),
                ],
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
                Text('ELYXR 2.0.5 · lymnal 2.0.5', style: mono(10, p.foot)),
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
                // A bracketed phosphor marker, not a filled chip — a terminal
                // section token in the accent colour.
                Text('[$num]',
                    style: mono(12, p.a, weight: FontWeight.w600)),
                const SizedBox(width: 9),
                Text(title, style: glass(17, p.bright)),
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
    // Watch so the tapped swatch's mini-tube (and the whole app) update live as
    // it's dragged.
    final settings = context.watch<SettingsController>();
    return Row(
      children: [
        for (final accent in Accent.values)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 4),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                // Press picks the phosphor; drag up/down pushes its intensity —
                // saturation (and glow) for a colour, lightness for mono. Double-
                // tap resets. The whole tube responds live.
                onTapDown: (_) => settings.accent = accent,
                onVerticalDragUpdate: (d) {
                  final up = -(d.primaryDelta ?? 0);
                  if (accent == Accent.mono) {
                    settings.monoL = settings.monoL + up * 0.0026;
                  } else {
                    settings.accentSat = settings.accentSat + up * 0.006;
                  }
                },
                onDoubleTap: () {
                  if (accent == Accent.mono) {
                    settings.monoL = 0.72;
                  } else {
                    settings.accentSat = 1.0;
                  }
                },
                child: _swatch(accent, accent == settings.accent, palette, settings),
              ),
            ),
          ),
      ],
    );
  }

  /// Each swatch is a miniature tube in that colour, previewing the machine
  /// rather than showing a paint chip. The selected one shows at the current
  /// drag intensity; the rest sit at their neutral default.
  Widget _swatch(Accent accent, bool on, Palette base, SettingsController s) {
    final sp = Palette(accent, base.dark,
        sat: on ? s.accentSat : 1.0,
        monoL: accent == Accent.mono && on ? s.monoL : null);
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
        // Shrink the label to fit its narrower column (8 accents now) rather
        // than overflow — a smart squish, not a clip.
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(accent.label,
              style: chassis(10, on ? base.bright : base.mid, spacing: 0.1)),
        ),
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

/// The terminal-face picker: one chip per available face, each previewing its
/// own font so you read the choice in the choice. Swapping re-skins the whole
/// terminal live. Add a face by dropping a TTF in assets/fonts/, declaring it in
/// pubspec.yaml, and adding a row to kTermFaces — it shows up here automatically.
class _FacePicker extends StatelessWidget {
  final Palette palette;
  const _FacePicker({required this.palette});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final settings = context.watch<SettingsController>();
    // Many faces now, so they flow into a grid rather than one cramped row.
    // Three across, sized to the tube width; extra rows scroll with the list.
    return LayoutBuilder(builder: (context, constraints) {
      const cols = 3;
      const gap = 8.0;
      final w = (constraints.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(
        spacing: gap,
        runSpacing: 10,
        children: [
          for (final face in kTermFaces)
            SizedBox(
              width: w,
              child: GestureDetector(
                onTap: () => settings.termFont = face.family,
                behavior: HitTestBehavior.opaque,
                child: Builder(builder: (context) {
                  final on = settings.termFont == face.family;
                  return Column(
                    children: [
                      Container(
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: p.dark ? const Color(0xFF030604) : const Color(0xFFf2f7f3),
                          border: Border.all(color: on ? p.a : p.dim),
                          borderRadius: BorderRadius.circular(2),
                        ),
                        // "Aa" rendered in the face itself — a live specimen.
                        child: Text('Aa',
                            style: TextStyle(
                              fontFamily: face.family,
                              fontSize: 24,
                              color: on ? p.a : p.foot,
                              shadows: on ? [Shadow(color: p.a, blurRadius: 10)] : null,
                            )),
                      ),
                      const SizedBox(height: 5),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(face.label,
                            style: chassis(9.5, on ? p.bright : p.mid, spacing: 0.08)),
                      ),
                    ],
                  );
                }),
              ),
            ),
        ],
      );
    });
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
        // The mount path only matters where the gate can run (a Linux client);
        // in server mode there's no mount, so it isn't shown.
        if (settings.appMode == AppMode.client && Platform.isLinux)
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
