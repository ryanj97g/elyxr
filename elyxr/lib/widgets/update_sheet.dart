// The update prompt, shared by the server's "Update now" and the client's
// "Update available". Because the update rebuilds the app itself, the app can't
// stay open through it — so this explains that elyxr will close and reopen, and
// on confirm it hands off to the detached updater and quits.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../design/text.dart';
import '../design/tokens.dart';
import '../state/updater.dart';

Future<void> showUpdateDialog(BuildContext context, Palette p) async {
  final updater = context.read<UpdateController>();
  final go = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: p.tubeBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(color: p.dim),
      ),
      title: Text('Update this device', style: glass(22, p.bright)),
      content: Text(
        'elyxr will close, update, and reopen on its own. That takes a few '
        'minutes — nothing else is needed, and no password is asked.',
        style: glass(16, p.soft),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text('NOT NOW', style: chassis(11, p.mid, spacing: 0.1)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text('UPDATE & RESTART', style: chassis(11, p.a, spacing: 0.1)),
        ),
      ],
    ),
  );
  if (go == true) {
    await updater.startAndRestart();
    // If it returned, spawning failed; show why.
    if (updater.error != null && context.mounted) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: p.tubeBg,
          title: Text('Update didn\'t start', style: glass(20, p.bright)),
          content: Text(updater.error!, style: glass(15, const Color(0xFFf5b942))),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('CLOSE', style: chassis(11, p.a, spacing: 0.1)),
            ),
          ],
        ),
      );
    }
  }
}

/// A thin strip a client shows when the server is on a newer build. Tapping it
/// updates this device and restarts the app.
class UpdateBanner extends StatelessWidget {
  final Palette p;
  const UpdateBanner({super.key, required this.p});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => showUpdateDialog(context, p),
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        color: p.a,
        padding: const EdgeInsets.fromLTRB(15, 8, 15, 8),
        child: Row(
          children: [
            Expanded(
              child: Text('A newer version is ready — tap to update this device.',
                  style: glass(15, p.ink)),
            ),
            const SizedBox(width: 8),
            Text('UPDATE ▸', style: chassis(11, p.ink, weight: FontWeight.w700, spacing: 0.1)),
          ],
        ),
      ),
    );
  }
}
