// ignore_for_file: file_names

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

typedef ThemeRevealCapture =
    Future<ui.Image> Function(
      RenderRepaintBoundary boundary,
      double pixelRatio,
    );

/// Captures the current frame and reveals the next theme from a tap origin.
class ThemeCircularRevealHost extends StatefulWidget {
  const ThemeCircularRevealHost({super.key, required this.child});

  final Widget child;

  static const Duration animationDuration = Duration(milliseconds: 860);
  static const Curve animationCurve = Cubic(0.22, 0.0, 0.12, 1.0);

  static ThemeCircularRevealHostState? maybeOf(BuildContext context) {
    return context.findAncestorStateOfType<ThemeCircularRevealHostState>();
  }

  /// Returns the distance to the farthest corner so the circle covers the screen.
  static double maxRadius({required Offset origin, required Size size}) {
    final dx = math.max(origin.dx, size.width - origin.dx);
    final dy = math.max(origin.dy, size.height - origin.dy);
    return Offset(dx, dy).distance;
  }

  /// Soft edge width so the expanding circle does not look like a hard cut.
  static double featherFor(double maxRadius) {
    return (maxRadius * 0.14).clamp(72.0, 200.0);
  }

  /// Animated hole radius, including the feather that overshoots the corner.
  static double animatedRadius({
    required double progress,
    required double maxRadius,
    required double feather,
  }) {
    return progress * (maxRadius + feather);
  }

  /// Test hook that replaces [RenderRepaintBoundary.toImage] during capture.
  @visibleForTesting
  static ThemeRevealCapture? debugCaptureFrame;

  @override
  State<ThemeCircularRevealHost> createState() =>
      ThemeCircularRevealHostState();
}

class ThemeCircularRevealHostState extends State<ThemeCircularRevealHost>
    with SingleTickerProviderStateMixin {
  final GlobalKey _boundaryKey = GlobalKey();
  late final AnimationController _controller;
  late final Animation<double> _progress;
  ui.Image? _capturedImage;
  Offset _origin = Offset.zero;
  double _maxRadius = 0;
  double _feather = 0;
  bool _busy = false;

  /// Creates the circular-reveal ticker used by sidebar theme switches.
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: ThemeCircularRevealHost.animationDuration,
    );
    _progress = CurvedAnimation(
      parent: _controller,
      curve: ThemeCircularRevealHost.animationCurve,
    );
  }

  /// Releases the captured frame and ticker.
  @override
  void dispose() {
    _controller.dispose();
    _capturedImage?.dispose();
    _capturedImage = null;
    super.dispose();
  }

  /// Snapshots the current UI, applies [applyTheme], then reveals from [origin].
  Future<void> switchTheme({
    required BuildContext originContext,
    required Future<void> Function() applyTheme,
  }) async {
    if (_busy) {
      return;
    }
    if (!originContext.mounted ||
        !mounted ||
        MediaQuery.disableAnimationsOf(context)) {
      await applyTheme();
      return;
    }

    final originBox = originContext.findRenderObject();
    final hostBox = context.findRenderObject();
    if (originBox is! RenderBox ||
        !originBox.hasSize ||
        hostBox is! RenderBox ||
        !hostBox.hasSize) {
      await applyTheme();
      return;
    }

    final origin = hostBox.globalToLocal(
      originBox.localToGlobal(originBox.size.center(Offset.zero)),
    );
    final maxRadius = ThemeCircularRevealHost.maxRadius(
      origin: origin,
      size: hostBox.size,
    );
    if (maxRadius <= 0) {
      await applyTheme();
      return;
    }

    final boundary = _boundaryKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) {
      await applyTheme();
      return;
    }

    _busy = true;
    ui.Image? image;
    try {
      // Capture the painted tap frame before applying the next theme.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !originContext.mounted) {
        _busy = false;
        return;
      }
      final pixelRatio = MediaQuery.devicePixelRatioOf(context).clamp(1.0, 2.0);
      final capture = ThemeCircularRevealHost.debugCaptureFrame;
      if (capture != null) {
        image = await capture(boundary, pixelRatio);
      } else {
        try {
          image = boundary.toImageSync(pixelRatio: pixelRatio);
        } catch (_) {
          image = await boundary.toImage(pixelRatio: pixelRatio);
        }
      }
    } catch (_) {
      _busy = false;
      await applyTheme();
      return;
    }

    if (!mounted) {
      image.dispose();
      _busy = false;
      return;
    }

    _capturedImage?.dispose();
    _capturedImage = image;
    _origin = origin;
    _maxRadius = maxRadius;
    _feather = ThemeCircularRevealHost.featherFor(maxRadius);
    _controller.value = 0;
    setState(() {});

    try {
      await applyTheme();
      if (!mounted) {
        return;
      }
      await _controller.forward();
    } finally {
      _capturedImage?.dispose();
      _capturedImage = null;
      _busy = false;
      if (mounted) {
        setState(() {});
      }
    }
  }

  /// Stacks the live child under a softly expanding hole in the snapshot.
  @override
  Widget build(BuildContext context) {
    final capturedImage = _capturedImage;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        RepaintBoundary(key: _boundaryKey, child: widget.child),
        if (capturedImage != null)
          Positioned.fill(
            key: const ValueKey<String>('themeCircularRevealOverlay'),
            child: ExcludeSemantics(
              child: AbsorbPointer(
                child: RepaintBoundary(
                  child: AnimatedBuilder(
                    animation: _progress,
                    builder: (context, child) {
                      return ShaderMask(
                        blendMode: BlendMode.dstOut,
                        shaderCallback: (bounds) {
                          return _revealShader(
                            origin: _origin,
                            radius: ThemeCircularRevealHost.animatedRadius(
                              progress: _progress.value,
                              maxRadius: _maxRadius,
                              feather: _feather,
                            ),
                            feather: _feather,
                          );
                        },
                        child: child,
                      );
                    },
                    child: SizedBox.expand(
                      child: RawImage(
                        image: capturedImage,
                        fit: BoxFit.fill,
                        filterQuality: FilterQuality.none,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Builds the soft circular mask that reveals only the area reached by expansion.
ui.Shader _revealShader({
  required Offset origin,
  required double radius,
  required double feather,
}) {
  final safeRadius = math.max(radius, 0.001);
  final innerStop = radius <= feather
      ? 0.0
      : ((radius - feather) / safeRadius).clamp(0.0, 0.999);
  if (innerStop <= 0) {
    return ui.Gradient.radial(
      origin,
      safeRadius,
      const <Color>[Color(0xFFFFFFFF), Color(0x73FFFFFF), Color(0x00FFFFFF)],
      const <double>[0.0, 0.42, 1.0],
    );
  }
  final midStop = innerStop + (1.0 - innerStop) * 0.42;
  return ui.Gradient.radial(
    origin,
    safeRadius,
    const <Color>[
      Color(0xFFFFFFFF),
      Color(0xFFFFFFFF),
      Color(0x73FFFFFF),
      Color(0x00FFFFFF),
    ],
    <double>[0.0, innerStop, midStop, 1.0],
  );
}
