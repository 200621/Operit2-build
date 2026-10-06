import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operit2/ui/common/components/RetainedPage.dart';
import 'package:xterm/src/ui/keyboard_visibility.dart';

/// Verifies that hidden terminals remove their global keyboard metric observers.
void main() {
  testWidgets('cached terminal observes keyboard changes only while active', (
    tester,
  ) async {
    final active = ValueNotifier<bool>(true);
    addTearDown(active.dispose);
    addTearDown(tester.view.resetViewInsets);
    var shown = 0;
    var hidden = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: active,
          child: KeyboardVisibilty(
            onKeyboardShow: () => shown += 1,
            onKeyboardHide: () => hidden += 1,
            child: const SizedBox.expand(),
          ),
          builder: (context, visible, child) =>
              RetainedPage(active: visible, child: child!),
        ),
      ),
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    expect(shown, 1);
    active.value = false;
    await tester.pump();
    await tester.pump();
    for (final inset in <double>[0, 150, 0, 200, 0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pump();
    }
    expect(shown, 1);
    expect(hidden, 0);
    active.value = true;
    await tester.pump();
    expect(hidden, 1);
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    await tester.pump();
    expect(shown, 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
