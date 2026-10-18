import 'package:flutter/widgets.dart';

/// A page-local bulk command, not a preference or a lock on local disclosures.
/// The revision lets later commands override manual choices without preventing
/// those choices between commands. Lazy and newly streamed rows inherit it too.
class AccordionExpansion extends InheritedWidget {
  const AccordionExpansion({
    super.key,
    required this.revision,
    required this.expanded,
    required super.child,
  });

  final int revision;
  final bool? expanded;

  static (int, bool?)? commandOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AccordionExpansion>();
    return scope == null ? null : (scope.revision, scope.expanded);
  }

  @override
  bool updateShouldNotify(AccordionExpansion oldWidget) =>
      revision != oldWidget.revision || expanded != oldWidget.expanded;
}
