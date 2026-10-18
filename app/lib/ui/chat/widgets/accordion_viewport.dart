import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';

// Matches the incumbent message-list and code-body breathing room.
const kAccordionGutter = 8.0;

/// Aligns the original disclosure heading once per expansion in this viewport.
class AccordionViewport extends StatefulWidget {
  const AccordionViewport({
    super.key,
    required this.controller,
    required this.child,
    this.reverse = false,
  });
  final ScrollController controller;
  final Widget child;
  final bool reverse;

  @override
  State<AccordionViewport> createState() => _AccordionViewportState();
}

class _AccordionViewportState extends State<AccordionViewport> {
  final _bounds = GlobalKey();
  final _entries = <_AccordionAnchorState>{};
  _AccordionAnchorState? _align;
  bool _scheduled = false;
  double _extent = 0;
  _AccordionAnchorState? _edgeOwner;
  _AccordionAnchorState? _return;

  @override
  void didUpdateWidget(AccordionViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.reverse != widget.reverse) {
      oldWidget.controller.removeListener(_schedule);
      widget.controller.addListener(_schedule);
      _align = _return = _edgeOwner = null;
      _extent = 0;
      for (final entry in _entries) {
        entry._bookmark = null;
      }
    }
  }

  void _capture(_AccordionAnchorState entry) {
    _return = null;
    _align = entry;
    final viewport = _rect(_bounds);
    final header = _rect(entry._header);
    if (viewport == null || header == null || !widget.controller.hasClients) {
      entry._bookmark = null;
      return;
    }
    entry._bookmark = _AccordionBookmark(
      widget.controller.position,
      header.top - viewport.top,
      widget.controller.position.pixels,
    );
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_schedule);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_schedule);
    super.dispose();
  }

  void _schedule() {
    if (_scheduled || !mounted) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) _measure();
    });
  }

  Rect? _rect(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _measure() {
    final viewport = _rect(_bounds);
    if (viewport == null || !widget.controller.hasClients) return;
    final expanded = _entries
        .where((e) => e.mounted && e.widget.expanded)
        .toList();
    // Only an edge disclosure that cannot reach the top receives extra space.
    if (_edgeOwner != null &&
        (!expanded.contains(_edgeOwner) ||
            (_rect(_edgeOwner!._card)?.height ?? viewport.height) >=
                viewport.height)) {
      final previousExtent = _extent;
      _edgeOwner = null;
      setState(() => _extent = 0);
      if (widget.reverse && previousExtent > 0) {
        final position = widget.controller.position;
        widget.controller.jumpTo(
          (position.pixels - previousExtent).clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          ),
        );
      }
      _schedule();
      return;
    }
    final returning = _return;
    if (returning != null) {
      final bookmark = returning._bookmark;
      if (returning.mounted &&
          !returning.widget.expanded &&
          bookmark != null &&
          identical(bookmark.position, widget.controller.position)) {
        if (!bookmark.materialized) {
          // A lazy reverse list may still have the expanded heading in its
          // keep-alive bucket. First lay out the collapsed row near its saved
          // position; only then use its current content displacement.
          setState(() => bookmark.materialized = true);
          bookmark.position.jumpTo(
            bookmark.pixels.clamp(
              bookmark.position.minScrollExtent,
              bookmark.position.maxScrollExtent,
            ),
          );
          _schedule();
          return;
        }
        final header = _rect(returning._header);
        if (header != null) {
          // The surviving heading is a content anchor: reverse-list insertions
          // and growth before it must not change the saved reading location.
          final delta = header.top - viewport.top - bookmark.displacement;
          final position = bookmark.position;
          final target = (position.pixels + (widget.reverse ? -delta : delta))
              .clamp(position.minScrollExtent, position.maxScrollExtent);
          if ((target - position.pixels).abs() > 0.5) {
            position.jumpTo(target);
          }
        }
      }
      _return = null;
      returning._bookmark = null;
    }
    final align = _align;
    if (align != null && expanded.contains(align)) {
      final header = _rect(align._header);
      if (header != null) {
        final delta = header.top - (viewport.top + kAccordionGutter);
        final position = widget.controller.position;
        final desired = position.pixels + (widget.reverse ? -delta : delta);
        final shortage = widget.reverse
            ? position.minScrollExtent - desired
            : desired - position.maxScrollExtent;
        if (shortage > 0.5 && _extent < viewport.height) {
          _edgeOwner = align;
          setState(
            () => _extent = (_extent + shortage).clamp(0.0, viewport.height),
          );
          _schedule();
          return;
        }
        _align = null;
        final target = desired.clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        if ((target - position.pixels).abs() > 0.5) {
          widget.controller.jumpTo(target);
          _schedule();
          return;
        }
      }
    } else {
      _align = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    _schedule();
    return _AccordionScope(
      owner: this,
      extent: _extent,
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (_) {
          _schedule();
          return false;
        },
        child: SizedBox(key: _bounds, child: widget.child),
      ),
    );
  }
}

class _AccordionScope extends InheritedWidget {
  const _AccordionScope({
    required this.owner,
    required this.extent,
    required super.child,
  });
  final _AccordionViewportState owner;
  final double extent;
  @override
  bool updateShouldNotify(_AccordionScope oldWidget) =>
      extent != oldWidget.extent;
}

/// Extra edge space is derived from this viewport, never a device pixel guess.
class AccordionEdgeSpace extends StatelessWidget {
  const AccordionEdgeSpace({super.key});
  @override
  Widget build(BuildContext context) => SizedBox(
    height:
        context.dependOnInheritedWidgetOfExactType<_AccordionScope>()?.extent ??
        0,
  );
}

class AccordionAnchor extends StatefulWidget {
  const AccordionAnchor({
    super.key,
    required this.expanded,
    required this.header,
    required this.body,
    this.onCollapse,
    this.bulkCommand,
  });
  // Bulk commands must not align/return every row to a competing bookmark.
  final Object? bulkCommand;
  final bool expanded;
  final Widget header;
  final Widget body;
  final VoidCallback? onCollapse;
  @override
  State<AccordionAnchor> createState() => _AccordionAnchorState();
}

class _AccordionBookmark {
  _AccordionBookmark(this.position, this.displacement, this.pixels);
  final ScrollPosition position;
  final double displacement;
  final double pixels;
  bool materialized = false;
}

class _AccordionAnchorState extends State<AccordionAnchor> {
  final _card = GlobalKey();
  final _header = GlobalKey();
  _AccordionViewportState? _owner;
  _AccordionBookmark? _bookmark;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final owner = context
        .dependOnInheritedWidgetOfExactType<_AccordionScope>()
        ?.owner;
    if (_owner != owner) {
      _owner?._entries.remove(this);
      _bookmark = null;
      _owner = owner;
      owner?._entries.add(this);
    }
    owner?._schedule();
  }

  @override
  void didUpdateWidget(AccordionAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bulkCommand != widget.bulkCommand) {
      _bookmark = null;
      if (_owner?._align == this) _owner?._align = null;
      if (_owner?._return == this) _owner?._return = null;
    } else if (!oldWidget.expanded && widget.expanded) {
      // didUpdateWidget still sees the collapsed render tree, before the new
      // body changes layout or the one-time expansion alignment runs.
      _owner?._capture(this);
    } else if (oldWidget.expanded && !widget.expanded && _bookmark != null) {
      _owner?._return = this;
    }
    _owner?._schedule();
  }

  @override
  void dispose() {
    _owner?._entries.remove(this);
    _owner?._schedule();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _owner?._schedule();
    return Column(
      key: _card,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          key: _header,
          // A nested heading/control must not double-tap its ancestor closed.
          child: MetaData(
            metaData: _AccordionHeaderMarker(),
            behavior: HitTestBehavior.translucent,
            child: widget.header,
          ),
        ),
        if (widget.expanded)
          RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: {
              _SurfaceDoubleTapRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                    _SurfaceDoubleTapRecognizer
                  >(
                    _SurfaceDoubleTapRecognizer.new,
                    (recognizer) => recognizer.onDoubleTap = widget.onCollapse,
                  ),
            },
            child: widget.body,
          ),
      ],
    );
  }
}

// Text and headers (including nested copy/wrap controls) are not collapse
// surfaces. SelectableText counts repeated taps itself; merely competing in
// its arena can steal word selection. Filter before entering that arena.
class _AccordionHeaderMarker {}

class _SurfaceDoubleTapRecognizer extends DoubleTapGestureRecognizer {
  @override
  bool isPointerAllowed(PointerDownEvent event) {
    final hit = HitTestResult();
    WidgetsBinding.instance.hitTestInView(hit, event.position, event.viewId);
    if (hit.path.any(
      (entry) =>
          entry.target is RenderParagraph || entry.target is RenderEditable,
    )) {
      return false;
    }
    if (hit.path.any(
      (entry) =>
          entry.target is RenderMetaData &&
          (entry.target as RenderMetaData).metaData is _AccordionHeaderMarker,
    )) {
      return false;
    }
    return super.isPointerAllowed(event);
  }
}
