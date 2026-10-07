import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operit2/ui/common/layout/ApplicationZoom.dart';
import 'package:webview_all/webview_all.dart';
import 'package:webview_all_linux/webview_all_linux.dart';

void main() {
  for (final dpr in <double>[1, 2]) {
    testWidgets(
      'GTK stays visible and receives combined content zoom at DPR $dpr',
      (tester) async {
        const prefix = 'com.abandoft.webview_all_linux';
        const root = MethodChannel(prefix);
        const instance = MethodChannel('$prefix/27');
        const events = MethodChannel('$prefix/27/events');
        final calls = <MethodCall>[];
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(root, (call) async => 27);
        messenger.setMockMethodCallHandler(instance, (call) async {
          calls.add(call);
          return null;
        });
        messenger.setMockMethodCallHandler(events, (_) async => null);
        addTearDown(() {
          messenger.setMockMethodCallHandler(root, null);
          messenger.setMockMethodCallHandler(instance, null);
          messenger.setMockMethodCallHandler(events, null);
        });
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize = Size(900 * dpr, 600 * dpr);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final zoom = ValueNotifier<double>(1);
        addTearDown(zoom.dispose);
        final controller = LinuxWebViewController(
          const LinuxWebViewControllerCreationParams(zoomFactor: 1.2),
        );
        expect(controller.requiresNativeApplicationZoom, isTrue);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, navigator) => ValueListenableBuilder<double>(
              valueListenable: zoom,
              child: navigator,
              builder: (context, value, navigator) => ApplicationZoomHost(
                zoom: value,
                onZoomChanged: (value) => zoom.value = value,
                child: navigator!,
              ),
            ),
            home: Stack(
              children: <Widget>[
                Positioned(
                  left: 90,
                  top: 80,
                  width: 240,
                  height: 160,
                  child: WebViewWidget.fromPlatform(
                    platform: LinuxWebViewWidget(
                      PlatformWebViewWidgetCreationParams(
                        controller: controller,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final factor in <double>[...ApplicationZoom.levels, 1]) {
          zoom.value = factor;
          await tester.pumpAndSettle();
          final frame =
              calls.lastWhere((call) => call.method == 'setFrame').arguments
                  as Map;
          expect(frame['visible'], isTrue);
          expect(frame['x'], closeTo(90 * factor, 0.001));
          expect(frame['y'], closeTo(80 * factor, 0.001));
          expect(frame['width'], closeTo(240 * factor, 0.001));
          expect(frame['height'], closeTo(160 * factor, 0.001));
          final nativeZoom =
              calls
                      .lastWhere((call) => call.method == 'setZoomFactor')
                      .arguments
                  as Map;
          expect(nativeZoom['zoomFactor'], closeTo(1.2 * factor, 0.000001));
          expect(tester.takeException(), isNull);
        }
        final pageZoomUpdate = controller.setZoomFactor(2);
        await tester.pumpAndSettle();
        await pageZoomUpdate;
        expect((calls.last.arguments as Map)['zoomFactor'], 2);
        zoom.value = 1.5;
        await tester.pumpAndSettle();
        final nativeZoom =
            calls.lastWhere((call) => call.method == 'setZoomFactor').arguments
                as Map;
        expect(nativeZoom['zoomFactor'], 3);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.runAsync(controller.dispose);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );
  }
}
