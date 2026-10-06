import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';

class KeyboardVisibilty extends StatefulWidget {
  /// Observes keyboard visibility only while terminal presentation is active.
  const KeyboardVisibilty({
    super.key,
    required this.child,
    this.onKeyboardShow,
    this.onKeyboardHide,
  });

  final Widget child;
  final VoidCallback? onKeyboardShow;
  final VoidCallback? onKeyboardHide;

  /// Creates the keyboard observer and activity listener owner.
  @override
  KeyboardVisibiltyState createState() => KeyboardVisibiltyState();
}

class KeyboardVisibiltyState extends State<KeyboardVisibilty>
    with WidgetsBindingObserver {
  ValueListenable<TickerModeData>? _activity;
  bool _observing = false;
  double _lastBottomInset = 0;

  /// Connects visibility changes to the terminal's retained-page activity.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final activity = TickerMode.getValuesNotifier(context);
    if (!identical(activity, _activity)) {
      _activity?.removeListener(_handleActivity);
      _activity = activity;
      activity.addListener(_handleActivity);
    }
    _handleActivity();
  }

  /// Registers no global window observer while the terminal is hidden.
  void _handleActivity() {
    final active = _activity!.value.enabled;
    if (_observing == active) return;
    _observing = active;
    if (active) {
      WidgetsBinding.instance.addObserver(this);
      didChangeMetrics();
    } else {
      WidgetsBinding.instance.removeObserver(this);
    }
  }

  /// Releases both activity and window listeners when the terminal is removed.
  @override
  void dispose() {
    _activity?.removeListener(_handleActivity);
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
    }
    super.dispose();
  }

  /// Notifies the visible terminal when keyboard visibility changes.
  @override
  void didChangeMetrics() {
    final bottomInset = View.of(context).viewInsets.bottom;
    if (bottomInset != _lastBottomInset) {
      if (bottomInset > 0) {
        widget.onKeyboardShow?.call();
      } else {
        widget.onKeyboardHide?.call();
      }
    }
    _lastBottomInset = bottomInset;
    super.didChangeMetrics();
  }

  /// Keeps terminal child identity stable across keyboard visibility changes.
  @override
  Widget build(BuildContext context) => widget.child;
}
