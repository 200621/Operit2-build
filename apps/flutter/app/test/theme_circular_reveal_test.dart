import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operit2/ui/theme/ThemeCircularRevealHost.dart';

/// Verifies that the sidebar circle continuously reveals the whole screen.
void main() {
  test(
    'bottom sidebar origins cover the farthest screen corner',
    _verifyScreenCoverage,
  );
  test(
    'the final solid circle covers every pixel without a screen fade',
    _verifyFinalCoverage,
  );
  testWidgets(
    'the circle reveals reached pixels before covering the entire screen',
    _verifyCircularPixels,
  );
  test('a top-left origin reaches the farthest bottom-right corner', () {
    const origin = Offset(48, 72);
    const size = Size(400, 800);
    expect(
      ThemeCircularRevealHost.maxRadius(origin: origin, size: size),
      (Offset(size.width, size.height) - origin).distance,
    );
  });

  test(
    'animated radius overshoots the farthest corner by the feather width',
    () {
      const origin = Offset(40, 60);
      const size = Size(400, 800);
      final maxRadius = ThemeCircularRevealHost.maxRadius(
        origin: origin,
        size: size,
      );
      final feather = ThemeCircularRevealHost.featherFor(maxRadius);
      expect(feather, inInclusiveRange(72.0, 200.0));
      expect(
        ThemeCircularRevealHost.animatedRadius(
          progress: 0,
          maxRadius: maxRadius,
          feather: feather,
        ),
        0,
      );
      expect(
        ThemeCircularRevealHost.animatedRadius(
          progress: 1,
          maxRadius: maxRadius,
          feather: feather,
        ),
        maxRadius + feather,
      );
    },
  );

  testWidgets('theme switch captures the frame and reveals from the button', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    var dark = false;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawColor(const Color(0xFFFFFFFF), BlendMode.src);
    final snapshot = recorder.endRecording().toImageSync(8, 8);
    ThemeCircularRevealHost.debugCaptureFrame = (boundary, pixelRatio) async =>
        snapshot;
    addTearDown(() {
      ThemeCircularRevealHost.debugCaptureFrame = null;
    });

    await tester.pumpWidget(
      MaterialApp(
        home: ThemeCircularRevealHost(
          child: StatefulBuilder(
            builder: (context, setState) {
              return ColoredBox(
                color: dark ? Colors.black : Colors.white,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Builder(
                    builder: (buttonContext) {
                      return IconButton(
                        tooltip: 'toggle',
                        onPressed: () {
                          unawaited(
                            ThemeCircularRevealHost.maybeOf(
                              buttonContext,
                            )!.switchTheme(
                              originContext: buttonContext,
                              applyTheme: () async {
                                setState(() {
                                  dark = true;
                                });
                              },
                            ),
                          );
                        },
                        icon: const Icon(Icons.dark_mode_outlined),
                      );
                    },
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('toggle'));
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('themeCircularRevealOverlay')),
      findsOneWidget,
    );
    expect(find.byType(ShaderMask), findsOneWidget);

    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('themeCircularRevealOverlay')),
      findsNothing,
    );
    expect(dark, isTrue);
  });
}

/// Checks every quadrant and the bottom sidebar against its actual farthest corner.
void _verifyScreenCoverage() {
  const size = Size(400, 800);
  final cases = <Offset, Offset>{
    Offset(40, 60): Offset(400, 800),
    Offset(360, 60): Offset(0, 800),
    Offset(40, 760): Offset(400, 0),
    Offset(360, 760): Offset(0, 0),
    Offset(200, 400): Offset(400, 800),
  };
  for (final entry in cases.entries) {
    expect(
      ThemeCircularRevealHost.maxRadius(origin: entry.key, size: size),
      closeTo((entry.value - entry.key).distance, 0.001),
    );
  }
  const landscapeOrigin = Offset(760, 360);
  expect(
    ThemeCircularRevealHost.maxRadius(
      origin: landscapeOrigin,
      size: const Size(800, 400),
    ),
    closeTo((Offset.zero - landscapeOrigin).distance, 0.001),
  );
}

/// Checks that the feather's fully revealed inner radius reaches all four corners.
void _verifyFinalCoverage() {
  const size = Size(400, 800);
  const origin = Offset(40, 760);
  final maxRadius = ThemeCircularRevealHost.maxRadius(
    origin: origin,
    size: size,
  );
  final feather = ThemeCircularRevealHost.featherFor(maxRadius);
  final solidRadius =
      ThemeCircularRevealHost.animatedRadius(
        progress: 1,
        maxRadius: maxRadius,
        feather: feather,
      ) -
      feather;
  for (final corner in <Offset>[
    Offset.zero,
    Offset(size.width, 0),
    Offset(0, size.height),
    Offset(size.width, size.height),
  ]) {
    expect((corner - origin).distance, lessThanOrEqualTo(solidRadius + 0.001));
  }
}

/// Samples the real snapshot mask to verify local expansion and complete coverage.
Future<void> _verifyCircularPixels(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(400, 800);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final dark = ValueNotifier<bool>(false);
  addTearDown(dark.dispose);
  final host = GlobalKey<ThemeCircularRevealHostState>();
  final frame = GlobalKey();
  final origin = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      home: RepaintBoundary(
        key: frame,
        child: ThemeCircularRevealHost(
          key: host,
          child: ValueListenableBuilder<bool>(
            valueListenable: dark,
            builder: (context, value, child) => ColoredBox(
              color: value ? Colors.black : Colors.white,
              child: Align(
                alignment: Alignment.bottomLeft,
                child: SizedBox(key: origin, width: 48, height: 48),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  final switching = host.currentState!.switchTheme(
    originContext: origin.currentContext!,
    applyTheme: () async {
      dark.value = true;
      await WidgetsBinding.instance.endOfFrame;
    },
  );
  await tester.pump();
  await tester.pump();
  await tester.pump();
  final overlay = find.byKey(
    const ValueKey<String>('themeCircularRevealOverlay'),
  );
  expect(overlay, findsOneWidget);
  expect(
    find.descendant(of: overlay, matching: find.byType(Opacity)),
    findsNothing,
  );

  await tester.pump(const Duration(milliseconds: 100));
  final expanding = await _captureRevealPixels(tester, frame);
  expect(_redAt(expanding, 24, 776), lessThan(16));
  expect(_redAt(expanding, 399, 0), greaterThan(240));

  await tester.pumpAndSettle();
  await switching;
  expect(overlay, findsNothing);
  final complete = await _captureRevealPixels(tester, frame);
  for (final point in <Offset>[
    const Offset(0, 0),
    const Offset(399, 0),
    const Offset(0, 799),
    const Offset(399, 799),
  ]) {
    expect(_redAt(complete, point.dx.toInt(), point.dy.toInt()), 0);
  }
}

/// Reads the composited screen pixels without replacing the production capture path.
Future<ByteData> _captureRevealPixels(
  WidgetTester tester,
  GlobalKey frame,
) async {
  final boundary =
      frame.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final pixels = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    } finally {
      image.dispose();
    }
  });
  return pixels!;
}

/// Returns the red channel of a pixel in the fixed-width black-and-white test frame.
int _redAt(ByteData pixels, int x, int y) {
  return pixels.getUint8((y * 400 + x) * 4);
}
