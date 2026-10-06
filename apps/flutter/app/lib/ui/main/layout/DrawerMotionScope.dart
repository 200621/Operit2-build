// ignore_for_file: file_names

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Exposes drawer motion to page-local snapshot owners without freezing a host.
class DrawerMotionScope extends InheritedWidget {
  /// Creates a scope for the drawer's motion lifecycle.
  const DrawerMotionScope({
    super.key,
    required this.isAnimating,
    required this.contentActivation,
    required super.child,
  });

  final ValueListenable<bool> isAnimating;
  final ValueListenable<int> contentActivation;

  /// Returns the motion source installed by the surrounding drawer layout.
  static DrawerMotionScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DrawerMotionScope>();

  /// Rebinds page owners only when the motion source itself changes.
  @override
  bool updateShouldNotify(DrawerMotionScope oldWidget) =>
      isAnimating != oldWidget.isAnimating ||
      contentActivation != oldWidget.contentActivation;
}
