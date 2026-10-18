import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// A reverse feed inserts below the reader. Preserve a real laid-out row,
/// not maxScrollExtent (which is only an estimate in a lazy variable-height list).
class ActivityScrollController extends ScrollController {
  RenderBox? _anchor;
  _ActivityRowBox? _row;
  double? _distance;

  void preserve(Iterable<GlobalKey> rows) {
    releaseAnchor();
    if (!hasClients) return;
    (position as _ActivityPosition)._followingBottom = position.pixels <= 1;
    if (position.pixels <= 1) return;
    for (final key in rows) {
      final box = key.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final viewport = RenderAbstractViewport.maybeOf(box);
      if (viewport == null) continue;
      if (viewport is! RenderBox) continue;
      final top = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
      if (top + box.size.height <= 0 || top >= position.viewportDimension) {
        continue;
      }
      RenderObject row = box;
      while (row.parent != null && row.parent is! RenderSliverMultiBoxAdaptor) {
        row = row.parent!;
      }
      final data = row.parentData;
      if (row is! RenderBox ||
          data is! SliverMultiBoxAdaptorParentData ||
          data.layoutOffset == null) {
        continue;
      }
      _anchor = row;
      _row = box is _ActivityRowBox ? box : null;
      _distance =
          data.layoutOffset! + (_row?.laidOutHeight ?? 0) - position.pixels;
      return;
    }
  }

  double? _target() {
    final anchor = _anchor;
    final distance = _distance;
    if (anchor == null || distance == null || !anchor.attached) return null;
    final data = anchor.parentData;
    return data is SliverMultiBoxAdaptorParentData && data.layoutOffset != null
        ? data.layoutOffset! + (_row?.laidOutHeight ?? 0) - distance
        : null;
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _ActivityPosition(
    physics: physics,
    context: context,
    oldPosition: oldPosition,
    target: _target,
  );

  void releaseAnchor() {
    _anchor = null;
    _row = null;
    _distance = null;
  }
}

/// Cache the row height during its own layout. Reading arbitrary RenderBox.size
/// from the viewport's dimension callback violates Flutter's layout contract.
class ActivityRow extends SingleChildRenderObjectWidget {
  const ActivityRow({super.key, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _ActivityRowBox();
}

class _ActivityRowBox extends RenderProxyBox {
  double laidOutHeight = 0;

  @override
  void performLayout() {
    super.performLayout();
    laidOutHeight = size.height;
  }
}

class _ActivityPosition extends ScrollPositionWithSingleContext {
  _ActivityPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
    required this.target,
  });
  final double? Function() target;
  double _viewportCorrection = 0;
  bool _followingBottom = true;

  @override
  void jumpTo(double value) {
    _followingBottom = value <= 1;
    super.jumpTo(value);
  }

  @override
  void applyUserOffset(double delta) {
    _followingBottom = false;
    super.applyUserOffset(delta);
  }

  @override
  void pointerScroll(double delta) {
    _followingBottom = false;
    super.pointerScroll(delta);
  }

  @override
  Future<void> animateTo(
    double to, {
    required Duration duration,
    required Curve curve,
  }) async {
    _followingBottom = false;
    await super.animateTo(to, duration: duration, curve: curve);
    if (pixels <= 1) _followingBottom = true;
  }

  @override
  bool applyViewportDimension(double viewportDimension) {
    if (hasViewportDimension && pixels > 1) {
      _viewportCorrection += this.viewportDimension - viewportDimension;
    }
    return super.applyViewportDimension(viewportDimension);
  }

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final anchored = _followingBottom ? minScrollExtent : target();
    final correcting = anchored != null || _viewportCorrection != 0;
    final desired = (anchored ?? (pixels + _viewportCorrection)).clamp(
      minScrollExtent,
      maxScrollExtent,
    );
    _viewportCorrection = 0;
    if (correcting && (desired - pixels).abs() > 0.5) {
      // Relayout before paint: a post-frame jump would flash displaced content.
      correctPixels(desired);
      return false;
    }
    return super.applyContentDimensions(minScrollExtent, maxScrollExtent);
  }
}
