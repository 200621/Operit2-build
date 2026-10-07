import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewLayer;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operit2/ui/common/layout/ApplicationZoom.dart';
import 'package:webview_all/webview_all.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

void main() {
  for (final dpr in <double>[1, 2]) {
    testWidgets(
      'native overlays use unscaled input coordinates at DPR $dpr',
      (tester) async {
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize = Size(900 * dpr, 600 * dpr);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final zoom = ValueNotifier<double>(1);
        addTearDown(zoom.dispose);
        final probeKey = GlobalKey();
        PointerDownEvent? lastPointer;
        final platform = _ProbePlatformView(
          probeKey: probeKey,
          onPointerDown: (event) => lastPointer = event,
        );
        await tester.pumpWidget(_zoomApp(zoom, platform));
        await tester.pumpAndSettle();
        final initialState = tester.state(find.byKey(probeKey));

        // Visit both sides of 1x and return to it without remounting the view.
        for (final scale in <double>[...ApplicationZoom.levels, 1]) {
          zoom.value = scale;
          await tester.pumpAndSettle();
          final box = probeKey.currentContext!.findRenderObject()! as RenderBox;
          final origin = box.localToGlobal(Offset.zero);
          expect(origin.dx, closeTo(90 * scale, 0.001));
          expect(origin.dy, closeTo(80 * scale, 0.001));
          expect(box.size.width, closeTo(240 * scale, 0.001));
          expect(box.size.height, closeTo(160 * scale, 0.001));
          final controller = platform.params.controller as _ProbeController;
          expect(controller.applicationZoomFactors.last, scale);

          // A raw NSView coordinate conversion cannot account for a CALayer
          // scale. Require the platform view's final paint scale to be 1x.
          final transform = box.getTransformTo(null);
          expect(transform.entry(0, 0), closeTo(1, 0.000001));
          expect(transform.entry(1, 1), closeTo(1, 0.000001));
          expect(transform.entry(0, 1), 0);
          expect(transform.entry(1, 0), 0);
          for (final local in <Offset>[
            const Offset(2, 2),
            box.size.center(Offset.zero),
            Offset(box.size.width - 2, box.size.height - 2),
          ]) {
            lastPointer = null;
            await tester.tapAt(origin + local);
            expect(lastPointer, isNotNull);
            expect(lastPointer!.localPosition.dx, closeTo(local.dx, 0.001));
            expect(lastPointer!.localPosition.dy, closeTo(local.dy, 0.001));
          }
          expect(tester.state(find.byKey(probeKey)), same(initialState));
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant(<TargetPlatform>{
        TargetPlatform.macOS,
        TargetPlatform.linux,
      }),
    );
  }

  testWidgets(
    'AppKit platform layer resizes across zoom changes without recreation',
    (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(1800, 1200);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform_views,
          null,
        ),
      );
      final zoom = ValueNotifier<double>(1);
      addTearDown(zoom.dispose);
      await tester.pumpWidget(_zoomApp(zoom, _AppKitPlatformView()));
      await tester.pumpAndSettle();
      final nativeState = tester.state(find.byType(AppKitView));
      final viewId = tester.layers.whereType<PlatformViewLayer>().single.viewId;
      for (final scale in <double>[0.7, 1.5, 1]) {
        zoom.value = scale;
        await tester.pumpAndSettle();
        final nativeLayer = tester.layers.whereType<PlatformViewLayer>().single;
        expect(nativeLayer.viewId, viewId);
        expect(nativeLayer.rect.width, closeTo(240 * scale, 0.001));
        expect(nativeLayer.rect.height, closeTo(160 * scale, 0.001));
        final box = tester.renderObject<RenderBox>(find.byType(AppKitView));
        expect(box.getTransformTo(null).entry(0, 0), closeTo(1, 0.000001));
        expect(box.getTransformTo(null).entry(1, 1), closeTo(1, 0.000001));
        expect(tester.state(find.byType(AppKitView)), same(nativeState));
        expect(tester.takeException(), isNull);
      }
      expect(calls.where((call) => call.method == 'create'), hasLength(1));
      expect(calls.where((call) => call.method == 'dispose'), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(calls.where((call) => call.method == 'dispose'), hasLength(1));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  for (final target in TargetPlatform.values.where(
    (target) =>
        target != TargetPlatform.macOS && target != TargetPlatform.linux,
  )) {
    testWidgets(
      '$target retains existing WebView application scaling',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(900, 600);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final zoom = ValueNotifier<double>(1.5);
        addTearDown(zoom.dispose);
        final probeKey = GlobalKey();
        await tester.pumpWidget(
          _zoomApp(
            zoom,
            _ProbePlatformView(probeKey: probeKey, onPointerDown: (_) {}),
          ),
        );
        await tester.pumpAndSettle();
        final box = probeKey.currentContext!.findRenderObject()! as RenderBox;
        expect(box.size, const Size(240, 160));
        final controller =
            probeKey.currentContext!
                    .findAncestorWidgetOfExactType<WebViewWidget>()!
                    .platform
                    .params
                    .controller
                as _ProbeController;
        expect(controller.applicationZoomFactors, isEmpty);
        final transform = box.getTransformTo(null);
        expect(transform.entry(0, 0), closeTo(1.5, 0.000001));
        expect(transform.entry(1, 1), closeTo(1.5, 0.000001));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant.only(target),
    );
  }

  testWidgets(
    'macOS WebView works without an application scale scope',
    (tester) async {
      final probeKey = GlobalKey();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 240,
              height: 160,
              child: WebViewWidget.fromPlatform(
                platform: _ProbePlatformView(
                  probeKey: probeKey,
                  onPointerDown: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      final box = probeKey.currentContext!.findRenderObject()! as RenderBox;
      expect(box.size, const Size(240, 160));
      expect(box.getTransformTo(null).entry(0, 0), 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}

Widget _zoomApp(ValueNotifier<double> zoom, PlatformWebViewWidget platform) {
  return MaterialApp(
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
          child: WebViewWidget.fromPlatform(platform: platform),
        ),
      ],
    ),
  );
}

class _ProbeController extends PlatformWebViewController {
  _ProbeController()
    : super.implementation(const PlatformWebViewControllerCreationParams());

  @override
  bool get requiresNativeApplicationZoom =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;

  final List<double> applicationZoomFactors = <double>[];

  @override
  Future<void> setApplicationZoomFactor(double zoomFactor) async {
    applicationZoomFactors.add(zoomFactor);
  }
}

class _ProbePlatformView extends PlatformWebViewWidget {
  _ProbePlatformView({required this.probeKey, required this.onPointerDown})
    : super.implementation(
        PlatformWebViewWidgetCreationParams(controller: _ProbeController()),
      );

  final GlobalKey probeKey;
  final PointerDownEventListener onPointerDown;

  @override
  Widget build(BuildContext context) =>
      _NativeProbe(key: probeKey, onPointerDown: onPointerDown);
}

class _NativeProbe extends StatefulWidget {
  const _NativeProbe({super.key, required this.onPointerDown});

  final PointerDownEventListener onPointerDown;

  @override
  State<_NativeProbe> createState() => _NativeProbeState();
}

class _NativeProbeState extends State<_NativeProbe> {
  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: widget.onPointerDown,
    child: const ColoredBox(color: Colors.blue),
  );
}

class _AppKitPlatformView extends PlatformWebViewWidget {
  _AppKitPlatformView()
    : super.implementation(
        PlatformWebViewWidgetCreationParams(controller: _ProbeController()),
      );

  @override
  Widget build(BuildContext context) => const AppKitView(
    viewType: 'application-zoom-test',
    layoutDirection: TextDirection.ltr,
  );
}
