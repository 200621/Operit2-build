@TestOn('browser')
library;

import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;
import 'package:flutter_test/flutter_test.dart';
import 'package:operit2/ui/common/layout/ApplicationZoom.dart';
import 'package:webview_all/webview_all.dart';
import 'package:webview_all_web/webview_all_web.dart';

void main() {
  testWidgets(
    'Web keeps application paint zoom and independent iframe page zoom',
    (tester) async {
      final registry = _CapturingPlatformViewRegistry();
      ui_web.debugOverridePlatformViewRegistry(registry);
      addTearDown(() => ui_web.debugOverridePlatformViewRegistry(null));
      final params = WebWebViewControllerCreationParams();
      final platformController = WebWebViewController(params);
      final controller = WebViewController.fromPlatform(platformController);
      expect(platformController.requiresNativeApplicationZoom, isFalse);
      final zoom = ValueNotifier<double>(1.5);
      addTearDown(zoom.dispose);
      await controller.setZoomFactor(1.2);
      final platform = WebWebViewWidget(
        PlatformWebViewWidgetCreationParams(controller: platformController),
      );
      // Widget tests mock the engine's platform-view creation channel. Invoke
      // the registered production factory to check its real DOM container too.
      final viewport =
          registry.factories[params.iFrame.id]!(0) as web.HTMLDivElement;
      expect(viewport.firstElementChild, same(params.iFrame));
      final key = GlobalKey();
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
          home: Center(
            child: SizedBox(
              key: key,
              width: 240,
              height: 160,
              child: WebViewWidget.fromPlatform(platform: platform),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final nativeElement = tester.element(find.byType(HtmlElementView));
      expect(viewport.getAttribute('style'), contains('overflow: hidden'));
      for (final factor in ApplicationZoom.levels) {
        zoom.value = factor;
        await tester.pumpAndSettle();
        final box = key.currentContext!.findRenderObject()! as RenderBox;
        expect(box.getTransformTo(null).entry(0, 0), closeTo(factor, 0.000001));
        expect(params.iFrame.style.transform, 'scale(1.2)');
        expect(
          double.parse(params.iFrame.style.width.replaceAll('%', '')),
          closeTo(100 / 1.2, 0.0001),
        );
        expect(
          tester.element(find.byType(HtmlElementView)),
          same(nativeElement),
        );
      }
      await controller.setZoomFactor(2);
      expect(params.iFrame.style.transform, 'scale(2)');
      expect(params.iFrame.style.width, '50%');
      zoom.value = 1;
      await tester.pumpAndSettle();
      expect(params.iFrame.style.transform, 'scale(2)');
      await controller.setZoomFactor(1);
      expect(params.iFrame.style.width, '100%');
      expect(params.iFrame.style.transform, 'scale(1)');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'iframe zoom does not require page script access or change navigation',
    () async {
      final params = WebWebViewControllerCreationParams();
      final controller = WebWebViewController(params);
      await controller.setJavaScriptMode(JavaScriptMode.disabled);
      params.iFrame.src = 'https://example.invalid/cross-origin';
      final src = params.iFrame.src;
      final sandbox = params.iFrame.getAttribute('sandbox');
      await controller.setZoomFactor(1.5);
      expect(params.iFrame.src, src);
      expect(params.iFrame.getAttribute('sandbox'), sandbox);
      expect(params.iFrame.style.transform, 'scale(1.5)');
      for (final factor in <double>[0, -1, double.infinity, double.nan]) {
        await expectLater(
          controller.setZoomFactor(factor),
          throwsArgumentError,
        );
      }
      expect(params.iFrame.style.transform, 'scale(1.5)');
    },
  );
}

class _CapturingPlatformViewRegistry extends ui_web.PlatformViewRegistry {
  final factories = <String, ui_web.PlatformViewFactory>{};

  @override
  bool registerViewFactory(
    String viewType,
    Function viewFactory, {
    bool isVisible = true,
  }) {
    factories[viewType] = viewFactory as ui_web.PlatformViewFactory;
    return true;
  }
}
