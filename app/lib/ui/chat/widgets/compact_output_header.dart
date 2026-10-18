import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The disclosure target is separate from copy/wrap controls.
class CompactOutputHeader extends StatelessWidget {
  const CompactOutputHeader({
    super.key,
    required this.title,
    required this.expanded,
    required this.onToggle,
    required this.disclosureKey,
    this.status,
    this.color,
    this.icon,
    this.controls = const [],
    this.statusAction,
  });
  final String title;
  final bool expanded;
  final VoidCallback onToggle;
  final Key disclosureKey;
  final String? status;
  final Color? color;
  final IconData? icon;
  // Each owning icon action has its own 48dp target.
  final List<Widget> controls;
  final Widget? statusAction;

  @override
  Widget build(BuildContext context) {
    final disclosure = Semantics(
      button: true,
      expanded: expanded,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowRight): () {
            if (!expanded) onToggle();
          },
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
            if (expanded) onToggle();
          },
        },
        child: Tooltip(
          message: title,
          excludeFromSemantics: true,
          child: InkWell(
            key: disclosureKey,
            onTap: onToggle,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              child: Row(
                children: [
                  Icon(
                    expanded ? Icons.expand_less : Icons.chevron_right,
                    size: 18,
                    color: context.colors.muted2,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.typo.monoSmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final statusIcon = status == null
        ? null
        : Semantics(
            container: true,
            child: Tooltip(
              message: status!,
              child: SizedBox(
                width: 24,
                height: 48,
                child: Icon(
                  icon ?? Icons.info_outline,
                  size: 16,
                  color: color,
                  semanticLabel: status,
                ),
              ),
            ),
          );
    return Material(
      type: MaterialType.transparency,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Reserve a readable identity, measured in incumbent type rather than
          // a device-width breakpoint. All actions keep independent 48dp slots.
          final identity = TextPainter(
            text: TextSpan(text: 'MMMMMMMMMM', style: context.typo.monoSmall),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 1,
          )..layout();
          final titleWidth = identity.width + 22;
          identity.dispose();
          final actionWidth =
              controls.length * 48 +
              (statusAction == null ? 0 : 48) +
              (statusIcon == null ? 0 : 24);
          final inline = constraints.maxWidth >= titleWidth + actionWidth;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: disclosure),
                  if (statusIcon != null && (inline || statusAction == null))
                    statusIcon,
                  if (inline) ...[?statusAction, ...controls],
                ],
              ),
              if (!inline && (statusAction != null || controls.isNotEmpty))
                Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (statusAction != null)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [?statusIcon, statusAction!],
                      ),
                    ...controls,
                  ],
                ),
            ],
          );
        },
      ),
    );
  }
}
