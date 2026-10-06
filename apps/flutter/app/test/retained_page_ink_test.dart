import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operit2/ui/common/components/RetainedPage.dart';

/// Builds a retained page below an ancestor Material that stays attached.
Widget _app({required bool active, required Widget child}) => MaterialApp(
  home: Scaffold(
    body: Material(
      key: const ValueKey('live-material'),
      type: MaterialType.transparency,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 360,
          height: 600,
          child: RetainedPage(active: active, child: child),
        ),
      ),
    ),
  ),
);

/// Verifies that parking a page does not leave ink in its live ancestor.
void main() {
  testWidgets(
    'retained ink decorations stay inside the parked render subtree',
    (tester) async {
      final child = Ink(
        color: Colors.red,
        width: 100,
        height: 40,
        child: const Text('Retained ink'),
      );
      await tester.pumpWidget(_app(active: true, child: child));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(_app(active: false, child: child));
      await tester.pump();
      tester
          .renderObject(find.byKey(const ValueKey('live-material')))
          .markNeedsPaint();
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(_app(active: true, child: child));
      await tester.pump();
      expect(find.text('Retained ink'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'retained InkWell ripples can sleep and wake while still animating',
    (tester) async {
      var taps = 0;
      final child = InkWell(
        onTap: () => taps++,
        child: const SizedBox(
          width: 160,
          height: 60,
          child: Center(child: Text('Tap retained page')),
        ),
      );
      await tester.pumpWidget(_app(active: true, child: child));
      await tester.pump();
      await tester.tap(find.text('Tap retained page'));
      await tester.pump(const Duration(milliseconds: 20));
      expect(taps, 1);
      for (var cycle = 0; cycle < 3; cycle++) {
        await tester.pumpWidget(_app(active: false, child: child));
        await tester.pump();
        for (var frame = 0; frame < 3; frame++) {
          tester
              .renderObject(find.byKey(const ValueKey('live-material')))
              .markNeedsPaint();
          await tester.pump(const Duration(milliseconds: 20));
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(_app(active: true, child: child));
        await tester.pump(const Duration(milliseconds: 20));
        expect(tester.takeException(), isNull);
      }
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'retained hover ink stays within its page while ancestors repaint',
    (tester) async {
      final child = InkWell(
        onTap: () {},
        child: const SizedBox(
          width: 160,
          height: 60,
          child: Text('Hover retained page'),
        ),
      );
      await tester.pumpWidget(_app(active: true, child: child));
      await tester.pump();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(700, 500));
      await mouse.moveTo(tester.getCenter(find.text('Hover retained page')));
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pumpWidget(_app(active: false, child: child));
      await tester.pump();
      tester
          .renderObject(find.byKey(const ValueKey('live-material')))
          .markNeedsPaint();
      await tester.pump(const Duration(milliseconds: 20));
      expect(tester.takeException(), isNull);
      await mouse.removePointer();
      await tester.pumpWidget(_app(active: true, child: child));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
