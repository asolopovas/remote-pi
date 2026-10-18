import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

enum SessionStatus {
  working,
  reconnecting,
  online,
  offline;

  static SessionStatus resolve({
    required bool isWorking,
    required bool isReconnecting,
    required bool isOnline,
  }) => isWorking
      ? working
      : isReconnecting
      ? reconnecting
      : isOnline
      ? online
      : offline;

  String get label => switch (this) {
    working => 'Working',
    reconnecting => 'Reconnecting',
    online => 'Online',
    offline => 'Offline',
  };

  Color color(AppColors colors) => switch (this) {
    working => colors.working,
    reconnecting => colors.warning,
    online => colors.success,
    offline => colors.muted,
  };
}

/// Decorative status glyph; pair with a visible status label for semantics.
/// Only busy work rotates. Reduced motion retains the distinct working shape.
class SessionStatusIndicator extends StatefulWidget {
  const SessionStatusIndicator({
    super.key,
    required this.status,
    this.size = 16,
  });

  final SessionStatus status;
  final double size;

  @override
  State<SessionStatusIndicator> createState() => _SessionStatusIndicatorState();
}

class _SessionStatusIndicatorState extends State<SessionStatusIndicator>
    with SingleTickerProviderStateMixin {
  late final _rotation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context);
    _updateMotion();
  }

  @override
  void didUpdateWidget(SessionStatusIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateMotion();
  }

  void _updateMotion() {
    if (widget.status == SessionStatus.working && !_reduceMotion) {
      if (!_rotation.isAnimating) _rotation.repeat();
    } else {
      _rotation.stop();
      _rotation.value = 0;
    }
  }

  @override
  void dispose() {
    _rotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.status.color(context.colors);
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: widget.size,
        child: widget.status == SessionStatus.working
            ? RotationTransition(
                turns: _rotation,
                child: Icon(Icons.autorenew, size: widget.size, color: color),
              )
            : Center(
                child: Container(
                  width: widget.size * 0.625,
                  height: widget.size * 0.625,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color,
                  ),
                ),
              ),
      ),
    );
  }
}
