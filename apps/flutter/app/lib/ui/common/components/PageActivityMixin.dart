// ignore_for_file: file_names

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Connects page-owned asynchronous work to the cached page's activity state.
///
/// The notifier listener runs even while the page's build scope is suspended.
/// Owners stop polling or subscriptions on sleep and refresh current data on wake.
/// Business operations owned by the runtime are independent of this UI lifecycle.
mixin PageActivityMixin<T extends StatefulWidget> on State<T> {
  ValueListenable<TickerModeData>? _pageActivity;
  bool _pageActive = false;

  /// Reports whether this page may currently perform presentation work.
  bool get isPageActive => _pageActive;

  /// Rebinds the activity signal when the retained page's ancestry changes.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final activity = TickerMode.getValuesNotifier(context);
    if (!identical(activity, _pageActivity)) {
      _pageActivity?.removeListener(_handlePageActivity);
      _pageActivity = activity;
      activity.addListener(_handlePageActivity);
    }
    _handlePageActivity();
  }

  /// Delivers each activity transition without requiring a descendant rebuild.
  void _handlePageActivity() {
    final active = _pageActivity!.value.enabled;
    if (_pageActive == active) {
      return;
    }
    _pageActive = active;
    onPageActivityChanged(active);
  }

  /// Starts or stops asynchronous work owned exclusively by the visible page.
  void onPageActivityChanged(bool active);

  /// Removes the lifecycle listener before the retained state is destroyed.
  @override
  void dispose() {
    _pageActivity?.removeListener(_handlePageActivity);
    super.dispose();
  }
}
