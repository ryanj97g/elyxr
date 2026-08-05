// The update strip, driven by UpdateController's stage. It appears while a
// background update runs and after it's ready, and does nothing when idle.
//   updating       → a muted "updating in the background" line (no action)
//   readyToRefresh → a gold "installed — refresh" the person taps when ready
//   failed         → an amber line they can tap to retry
// Used on a client (auto, when behind the server) and on a server (after the
// "update now" control kicks one off).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../design/text.dart';
import '../design/tokens.dart';
import '../state/updater.dart';

class UpdateBanner extends StatelessWidget {
  final Palette p;
  const UpdateBanner({super.key, required this.p});

  @override
  Widget build(BuildContext context) {
    final u = context.watch<UpdateController>();
    switch (u.stage) {
      case UpdateStage.updating:
        return _strip(
          bg: p.tubeBg,
          border: p.dim,
          fg: p.mid,
          text: 'Updating in the background — keep working.',
          action: null,
          onTap: null,
          actionColor: p.mid,
        );
      case UpdateStage.readyToRefresh:
        return _strip(
          bg: p.a,
          border: p.a,
          fg: p.ink,
          text: 'Update installed.',
          action: 'REFRESH ▸',
          onTap: () => u.refreshNow(),
          actionColor: p.ink,
        );
      case UpdateStage.failed:
        return _strip(
          bg: const Color(0xFF2e2f18),
          border: const Color(0xFFf5b942),
          fg: const Color(0xFFf5b942),
          text: u.error ?? 'The update didn\'t finish.',
          action: 'RETRY',
          onTap: () => u.retry(),
          actionColor: const Color(0xFFf5b942),
        );
      case UpdateStage.idle:
        return const SizedBox.shrink();
    }
  }

  Widget _strip({
    required Color bg,
    required Color border,
    required Color fg,
    required String text,
    required String? action,
    required VoidCallback? onTap,
    required Color actionColor,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: bg,
          border: Border(bottom: BorderSide(color: border)),
        ),
        padding: const EdgeInsets.fromLTRB(15, 8, 15, 8),
        child: Row(
          children: [
            Expanded(child: Text(text, style: glass(15, fg))),
            if (action != null) ...[
              const SizedBox(width: 8),
              Text(action, style: chassis(11, actionColor, weight: FontWeight.w700, spacing: 0.1)),
            ],
          ],
        ),
      ),
    );
  }
}
