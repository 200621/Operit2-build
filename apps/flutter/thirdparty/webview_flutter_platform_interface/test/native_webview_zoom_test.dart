import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

void main() {
  test(
    'application and page factors compose without replacing one another',
    () async {
      final applied = <double>[];
      final zoom = NativeWebViewZoom(
        applyZoom: (factor) async => applied.add(factor),
      );
      await zoom.setPageZoomFactor(1.2);
      await zoom.setApplicationZoomFactor(1.5);
      expect(applied.last, closeTo(1.8, 0.000001));
      await zoom.setPageZoomFactor(2);
      expect(applied.last, 3);
      await zoom.setApplicationZoomFactor(1);
      expect(applied.last, 2);
      await zoom.setPageZoomFactor(1);
      expect(applied.last, 1);
    },
  );

  test('custom initial page zoom survives application zoom changes', () async {
    final applied = <double>[];
    final zoom = NativeWebViewZoom(
      initialPageZoomFactor: 1.2,
      applyZoom: (factor) async => applied.add(factor),
    );
    await zoom.setApplicationZoomFactor(1.5);
    expect(applied.single, closeTo(1.8, 0.000001));
  });

  test(
    'invalid factors and overflow do not change the stored factors',
    () async {
      final applied = <double>[];
      final zoom = NativeWebViewZoom(
        applyZoom: (factor) async => applied.add(factor),
      );
      await zoom.setPageZoomFactor(2);
      for (final factor in <double>[
        0,
        -1,
        double.nan,
        double.infinity,
        1.7e308,
      ]) {
        expect(
          () => zoom.setApplicationZoomFactor(factor),
          throwsArgumentError,
        );
      }
      await zoom.setApplicationZoomFactor(1.5);
      expect(applied.last, 3);
    },
  );

  test(
    'native requests cannot complete out of order during creation',
    () async {
      final started = Completer<void>();
      final released = Completer<void>();
      final applied = <double>[];
      final zoom = NativeWebViewZoom(
        applyZoom: (factor) async {
          applied.add(factor);
          if (applied.length == 1) {
            started.complete();
            await released.future;
          }
        },
      );
      final first = zoom.setPageZoomFactor(1.2);
      final second = zoom.setApplicationZoomFactor(1.5);
      final third = zoom.setPageZoomFactor(2);
      await started.future;
      expect(applied, <double>[1.2]);
      released.complete();
      await Future.wait(<Future<void>>[first, second, third]);
      expect(applied[1], closeTo(1.8, 0.000001));
      expect(applied[2], 3);
    },
  );

  test(
    'failed native requests report errors but later zoom changes recover',
    () async {
      var requests = 0;
      final applied = <double>[];
      final zoom = NativeWebViewZoom(
        applyZoom: (factor) async {
          if (requests++ == 0) throw StateError('native view unavailable');
          applied.add(factor);
        },
      );
      await expectLater(zoom.setPageZoomFactor(1.2), throwsStateError);
      await zoom.setApplicationZoomFactor(1.5);
      expect(applied.single, closeTo(1.8, 0.000001));
    },
  );
}
