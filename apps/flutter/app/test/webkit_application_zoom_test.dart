import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewLayer;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operit2/ui/common/layout/ApplicationZoom.dart';
import 'package:webview_all/webview_all.dart';
import 'package:webview_flutter_wkwebview/src/common/web_kit.g.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

void main() {
  final variant = TargetPlatformVariant.only(TargetPlatform.macOS);

  testWidgets(
    'WebKit content follows application zoom while retaining browser zoom',
    (tester) async {
      final nativeView = _fakeWebKit(tester);
      final nativeZooms = <double>[];
      _mockZoomChannel(tester, (call) async {
        final arguments = call.arguments as Map;
        expect(
          arguments['identifier'],
          PigeonInstanceManager.instance.getIdentifier(nativeView),
        );
        nativeZooms.add(arguments['zoomFactor'] as double);
      });
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(1800, 1200);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final applicationZoom = ValueNotifier<double>(1.5);
      addTearDown(applicationZoom.dispose);
      final controller = WebKitWebViewController(
        const PlatformWebViewControllerCreationParams(),
      );
      final browser = WebViewController.fromPlatform(controller);
      await browser.setZoomFactor(1.2);
      final webView = WebViewWidget.fromPlatform(
        platform: WebKitWebViewWidget(
          PlatformWebViewWidgetCreationParams(controller: controller),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, navigator) => ValueListenableBuilder<double>(
            valueListenable: applicationZoom,
            child: navigator,
            builder: (context, value, navigator) => ApplicationZoomHost(
              zoom: value,
              onZoomChanged: (value) => applicationZoom.value = value,
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
                child: webView,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      final nativeState = tester.state(find.byType(AppKitView));
      expect(
        nativeZooms,
        orderedEquals(<double>[1.2, 1.8].map((v) => closeTo(v, 0.000001))),
      );
      for (final scale in ApplicationZoom.levels) {
        applicationZoom.value = scale;
        await tester.pumpAndSettle();
        expect(nativeZooms.last, closeTo(scale * 1.2, 0.000001));
        final layer = tester.layers.whereType<PlatformViewLayer>().single;
        expect(layer.rect.width, closeTo(240 * scale, 0.001));
        // Preserve the original CSS viewport width, not just the NSView frame:
        // enlarging the native frame must be paired with native content zoom.
        expect(layer.rect.width / nativeZooms.last, closeTo(240 / 1.2, 0.001));
        final box = tester.renderObject<RenderBox>(find.byType(AppKitView));
        expect(box.getTransformTo(null).entry(0, 0), closeTo(1, 0.000001));
        expect(box.getTransformTo(null).entry(1, 1), closeTo(1, 0.000001));
        expect(tester.state(find.byType(AppKitView)), same(nativeState));
      }
      await browser.setZoomFactor(2);
      expect(nativeZooms.last, 3); // Application 1.5x * browser 2x.
      applicationZoom.value = 1;
      await tester.pumpAndSettle();
      expect(nativeZooms.last, 2); // Resetting app zoom retains browser zoom.
      await browser.setZoomFactor(1);
      expect(nativeZooms.last, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    variant: variant,
  );

  testWidgets(
    'native zoom updates are ordered while initial registration is pending',
    (tester) async {
      _fakeWebKit(tester);
      final nativeZooms = <double>[];
      final firstUpdate = Completer<void>();
      final firstStarted = Completer<void>();
      _mockZoomChannel(tester, (call) async {
        nativeZooms.add((call.arguments as Map)['zoomFactor'] as double);
        if (nativeZooms.length == 1) {
          firstStarted.complete();
          await firstUpdate.future;
        }
      });
      final controller = WebKitWebViewController(
        const PlatformWebViewControllerCreationParams(),
      );
      final first = controller.setZoomFactor(1.2);
      final second = controller.setApplicationZoomFactor(1.5);
      final third = controller.setZoomFactor(2);
      await firstStarted.future;
      expect(nativeZooms, <double>[1.2]);
      firstUpdate.complete();
      await Future.wait(<Future<void>>[first, second, third]);
      expect(nativeZooms[1], closeTo(1.8, 0.000001));
      expect(nativeZooms[2], 3);
      expect(tester.takeException(), isNull);
    },
    variant: variant,
  );

  testWidgets(
    'a failed native update does not block subsequent content zoom updates',
    (tester) async {
      _fakeWebKit(tester);
      var count = 0;
      final nativeZooms = <double>[];
      _mockZoomChannel(tester, (call) async {
        if (count++ == 0) {
          throw PlatformException(code: 'transient');
        }
        nativeZooms.add((call.arguments as Map)['zoomFactor'] as double);
      });
      final controller = WebKitWebViewController(
        const PlatformWebViewControllerCreationParams(),
      );
      await expectLater(
        controller.setZoomFactor(1.2),
        throwsA(isA<PlatformException>()),
      );
      await controller.setApplicationZoomFactor(1.5);
      expect(nativeZooms.single, closeTo(1.8, 0.000001));
      expect(tester.takeException(), isNull);
    },
    variant: variant,
  );
}

void _mockZoomChannel(
  WidgetTester tester,
  Future<void> Function(MethodCall) handler,
) {
  const channel = MethodChannel('operit/webview_zoom');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
    call,
  ) async {
    expect(call.method, 'setPageZoom');
    await handler(call);
    return null;
  });
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    ),
  );
}

_FakeMacWebView _fakeWebKit(WidgetTester tester) {
  final view = _FakeMacWebView();
  PigeonInstanceManager.instance.addDartCreatedInstance(view);
  PigeonOverrides.wKWebViewConfiguration_new = ({observeValue}) =>
      _FakeConfiguration();
  PigeonOverrides.nSViewWKWebView_new =
      ({required initialConfiguration, observeValue}) => view;
  PigeonOverrides.wKUIDelegate_new =
      ({
        required requestMediaCapturePermission,
        required runJavaScriptConfirmPanel,
        observeValue,
        onCreateWebView,
        runJavaScriptAlertPanel,
        runJavaScriptTextInputPanel,
      }) => _FakeUIDelegate();
  addTearDown(PigeonOverrides.pigeon_reset);
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform_views,
    (_) async => null,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      null,
    ),
  );
  return view;
}

class _FakeConfiguration extends WKWebViewConfiguration {
  _FakeConfiguration() : super.pigeon_detached();

  @override
  Future<void> setMediaTypesRequiringUserActionForPlayback(
    AudiovisualMediaType value,
  ) async {}

  @override
  Future<void> setAllowsInlineMediaPlayback(bool value) async {}
}

class _FakeMacWebView extends NSViewWKWebView {
  _FakeMacWebView() : super.pigeon_detached();

  @override
  Future<void> addObserver(
    NSObject observer,
    String keyPath,
    List<KeyValueObservingOptions> options,
  ) async {}

  @override
  Future<void> setUIDelegate(WKUIDelegate? delegate) async {}
}

class _FakeUIDelegate extends WKUIDelegate {
  _FakeUIDelegate()
    : super.pigeon_detached(
        requestMediaCapturePermission: (_, _, _, _, _) async =>
            PermissionDecision.prompt,
        runJavaScriptConfirmPanel: (_, _, _, _) async => false,
      );
}
