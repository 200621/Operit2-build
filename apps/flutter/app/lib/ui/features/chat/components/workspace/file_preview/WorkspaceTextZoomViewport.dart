// ignore_for_file: file_names

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Scales text while optionally fitting its wrapping width to the viewport.
class WorkspaceTextZoomViewport extends SingleChildRenderObjectWidget {
  /// Creates a zoom boundary whose input coordinates match its painted text.
  const WorkspaceTextZoomViewport({
    super.key,
    required this.scale,
    required this.horizontalOffset,
    required this.wrapToViewport,
    required super.child,
  });

  final double scale;
  final double horizontalOffset;
  final bool wrapToViewport;

  /// Creates the shared layout, paint, hit-test, and semantics transform.
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTextZoomViewport(
        scale: scale,
        horizontalOffset: horizontalOffset,
        wrapToViewport: wrapToViewport,
      );

  /// Updates geometry in the rendering pipeline rather than after painting.
  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RenderTextZoomViewport).updateZoom(
      scale,
      horizontalOffset,
      wrapToViewport,
    );
  }
}

class _RenderTextZoomViewport extends RenderProxyBox {
  /// Creates a viewport with explicit wrapping and horizontal bounds.
  _RenderTextZoomViewport({
    required double scale,
    required double horizontalOffset,
    required bool wrapToViewport,
  }) : _scale = scale,
       _horizontalOffset = horizontalOffset,
       _wrapToViewport = wrapToViewport;

  double _scale;
  double _horizontalOffset;
  bool _wrapToViewport;

  /// Shares one affine transform between painting, selection, and hit testing.
  Matrix4 get _transform {
    final extent = size.width * (1 - _scale);
    final offset = _wrapToViewport
        ? 0.0
        : _horizontalOffset.clamp(extent < 0 ? extent : 0.0, 0.0);
    return Matrix4.diagonal3Values(_scale, _scale, 1)..setEntry(0, 3, offset);
  }

  /// Invalidates layout and paint together when the visible zoom changes.
  void updateZoom(double scale, double horizontalOffset, bool wrapToViewport) {
    if (_scale == scale &&
        _horizontalOffset == horizontalOffset &&
        _wrapToViewport == wrapToViewport) {
      return;
    }
    _scale = scale;
    _horizontalOffset = horizontalOffset;
    _wrapToViewport = wrapToViewport;
    markNeedsLayout();
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  /// Fits wrapped editor lines to the actual visible width at every scale.
  @override
  void performLayout() {
    assert(constraints.hasBoundedWidth && constraints.hasBoundedHeight);
    size = constraints.biggest;
    child!.layout(
      BoxConstraints.tightFor(
        width: _wrapToViewport ? size.width / _scale : size.width,
        height: size.height / _scale,
      ),
      parentUsesSize: true,
    );
  }

  /// Paints the text and cursor using the exact transform used by input.
  @override
  void paint(PaintingContext context, Offset offset) {
    context.pushTransform(needsCompositing, offset, _transform, super.paint);
  }

  /// Maps selection and scroll gestures into the unscaled text viewport.
  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    return result.addWithPaintTransform(
      transform: _transform,
      position: position,
      hitTest: (result, position) =>
          super.hitTestChildren(result, position: position),
    );
  }

  /// Exposes the same geometry to cursor overlays and accessibility clients.
  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.multiply(_transform);
  }
}
