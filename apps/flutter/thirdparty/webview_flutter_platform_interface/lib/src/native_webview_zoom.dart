/// Combines page and application zoom for views without native paint scaling.
///
/// Stores each factor separately and serializes native requests, including the
/// first request that may need to wait for native view creation. Failed requests
/// are reported to their caller without preventing later updates.
class NativeWebViewZoom {
  NativeWebViewZoom({
    required Future<void> Function(double) applyZoom,
    double initialPageZoomFactor = 1,
  }) : _applyZoom = applyZoom,
       _pageZoomFactor = initialPageZoomFactor {
    _validate(initialPageZoomFactor);
  }

  final Future<void> Function(double) _applyZoom;
  double _pageZoomFactor;
  double _applicationZoomFactor = 1;
  Future<void> _queue = Future<void>.value();

  Future<void> setPageZoomFactor(double factor) {
    _validate(factor);
    _validate(factor * _applicationZoomFactor);
    _pageZoomFactor = factor;
    return _apply();
  }

  Future<void> setApplicationZoomFactor(double factor) {
    _validate(factor);
    _validate(factor * _pageZoomFactor);
    if (_applicationZoomFactor == factor) {
      return _queue;
    }
    _applicationZoomFactor = factor;
    return _apply();
  }

  Future<void> _apply() {
    final double factor = _pageZoomFactor * _applicationZoomFactor;
    final Future<void> update = _queue.then((_) => _applyZoom(factor));
    _queue = update.catchError((Object _, StackTrace __) {});
    return update;
  }

  static void _validate(double factor) {
    if (!factor.isFinite || factor <= 0) {
      throw ArgumentError.value(factor, 'zoomFactor');
    }
  }
}
