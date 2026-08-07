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
    final i = widget.intensity;
    // A finger press reads best a touch brighter than a passing hover.
    final glow = _press ? i : i * 0.7;
    return MouseRegion(
      onEnter: (_) => _update(() => _hover = true),
      onExit: (_) => _update(() => _hover = false),
      child: Listener(
        onPointerDown: (_) => _update(() => _press = true),
        onPointerUp: (_) => _update(() => _press = false),
        onPointerCancel: (_) => _update(() => _press = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 130),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            borderRadius: widget.radius,
            boxShadow: _lit
                ? [
                    BoxShadow(
                      color: widget.accent.withValues(alpha: glow),
                      blurRadius: 14,
                      spreadRadius: -3,
                    ),
                  ]
                : const [],
          ),
          foregroundDecoration: BoxDecoration(
            borderRadius: widget.radius,
            // A whisper of accent wash over the surface — a highlight, never
            // enough to dull the text underneath.
            color: _lit ? widget.accent.withValues(alpha: glow * 0.3) : null,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
