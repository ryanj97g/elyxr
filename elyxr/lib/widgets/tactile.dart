// One interaction abstraction for "this is touchable," so a clickable surface
// lights the same phosphor glow on every device: a mouse *hovers* it on the
// desktop, a finger *presses* it on Android — both resolve to the same lit
// state. It never consumes the gesture (MouseRegion and Listener are passive),
// so the child keeps its own onTap/onLongPress handlers untouched.

import 'package:flutter/material.dart';

/// Wraps [child] and lights an accent glow when the pointer is over it (desktop
/// hover) or pressing it (touch). Passive — stack it around anything that
/// already handles taps.
class Tactile extends StatefulWidget {
  final Color accent;
  final BorderRadius? radius;
  final double intensity; // peak glow strength (glow alpha ≈ this)
  final Widget child;

  const Tactile({
    super.key,
    required this.accent,
    required this.child,
    this.radius,
    this.intensity = 0.14,
  });

  @override
  State<Tactile> createState() => _TactileState();
}

class _TactileState extends State<Tactile> {
  bool _hover = false; // pointer resting over it (desktop)
  bool _press = false; // pointer held down (touch, and desktop click)

  bool get _lit => _hover || _press;

  void _update(void Function() change) {
    final was = _lit;
    change();
    if (_lit != was) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // Press reads brighter than a passing hover.
    final k = _press ? 1.0 : 0.62;
    final a = widget.accent;
    return MouseRegion(
      onEnter: (_) => _update(() => _hover = true),
      onExit: (_) => _update(() => _hover = false),
      child: Listener(
        onPointerDown: (_) => _update(() => _press = true),
        onPointerUp: (_) => _update(() => _press = false),
        onPointerCancel: (_) => _update(() => _press = false),
        // The lit state: a bright accent outline plus a gentle wash, drawn in
        // front of the surface within the widget's own bounds so a clipping
        // parent (the file ListView) can't swallow it. A phosphor box-shadow
        // glow is added behind, visible wherever nothing clips it.
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            borderRadius: widget.radius,
            boxShadow: _lit
                ? [BoxShadow(color: a.withValues(alpha: 0.30 * k), blurRadius: 16, spreadRadius: -2)]
                : const [],
          ),
          foregroundDecoration: BoxDecoration(
            borderRadius: widget.radius,
            // A clear, bright accent outline — the unmistakable hover cue.
            border: _lit
                ? Border.all(color: a.withValues(alpha: 0.35 + 0.55 * k), width: 1.3)
                : null,
            // A light wash that keeps the text readable underneath.
            color: _lit ? a.withValues(alpha: 0.10 * k) : null,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
