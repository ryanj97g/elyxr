// The update strip, driven by UpdateController's stage. It appears while a
// background update runs and vanishes when the app relaunches itself.
//   updating          → a muted "updating in the background" line (no action)
//   waitingForUpload  → "restarting as soon as your upload finishes" (no action)
//   failed            → an amber line they can tap to retry
// The restart is automatic and silent — there's no confirm and no refresh
// button; the strip just narrates what's happening until the app reopens.

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
          text: 'Updating in the background — it\'ll restart itself when it\'s done.',
          action: null,
          onTap: null,
          actionColor: p.mid,
        );
      case UpdateStage.waitingForUpload:
        return _strip(
          bg: p.tubeBg,
          border: p.dim,
          fg: p.mid,
          text: 'Update ready — restarting as soon as your upload finishes.',
          action: null,
          onTap: null,
          actionColor: p.mid,
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
      case UpdateStage.upToDate:
        // Not a failure and not a job in progress — it's an answer, so it says
        // so plainly instead of borrowing the amber failure strip.
        return _strip(
          bg: p.tubeBg,
          border: p.dim,
          fg: p.mid,
          text: u.error ?? 'This device is already on the published build.',
          action: null,
          onTap: null,
          actionColor: p.mid,
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
