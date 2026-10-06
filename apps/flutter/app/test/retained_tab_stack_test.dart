import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operit2/ui/common/components/AnimatedLazyIndexedStack.dart';
import 'package:operit2/ui/common/components/LazyIndexedStack.dart';

/// Verifies that cached tab builders run only for visible or transitioning tabs.
void main() {
  for (final animated in <bool>[false, true]) {
    testWidgets(
      'cached tabs defer builders and preserve state (animated: $animated)',
      (tester) async {
        final keys = <GlobalKey<_TabProbeState>>[
          GlobalKey<_TabProbeState>(),
          GlobalKey<_TabProbeState>(),
        ];
        final builds = <int>[0, 0];
        final layouts = <int>[0, 0];

        /// Reconfigures the tab host without changing the retained tab identities.
        Future<void> pumpTabs(int index, double height, int revision) async {
          /// Records expensive item-builder work rather than lightweight host work.
          Widget buildTab(BuildContext context, int index) {
            builds[index] += 1;
            return _TabProbe(
              key: keys[index],
              index: index,
              layouts: layouts,
              revision: revision,
            );
          }

          final stack = animated
              ? AnimatedLazyIndexedStack(
                  index: index,
                  itemCount: 2,
                  itemBuilder: buildTab,
                )
              : LazyIndexedStack(
                  index: index,
                  itemCount: 2,
                  itemBuilder: buildTab,
                );
          await tester.pumpWidget(
            MaterialApp(
              home: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(width: 360, height: height, child: stack),
              ),
            ),
          );
        }

        await pumpTabs(0, 500, 0);
        await tester.pumpAndSettle();
        expect(builds[1], 0);
        final state = keys[0].currentState!;
        state.controller.text = 'tab draft';
        await pumpTabs(1, 500, 0);
        await tester.pumpAndSettle();
        final beforeBuilds = builds[0];
        final beforeLayouts = layouts[0];
        for (var revision = 1; revision <= 4; revision += 1) {
          await pumpTabs(1, 500 - revision * 50, revision);
          await tester.pumpAndSettle();
          expect(builds[0], beforeBuilds);
          expect(layouts[0], beforeLayouts);
          expect(keys[0].currentState, same(state));
          expect(tester.takeException(), isNull);
        }
        expect(state.widget.revision, 0);
        await pumpTabs(0, 300, 4);
        await tester.pumpAndSettle();
        expect(keys[0].currentState, same(state));
        expect(state.controller.text, 'tab draft');
        expect(state.widget.revision, 4);
        expect(builds[0], greaterThan(beforeBuilds));
        expect(layouts[0], greaterThan(beforeLayouts));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}

class _TabProbe extends StatefulWidget {
  /// Creates a stateful tab with observable layout-time computation.
  const _TabProbe({
    super.key,
    required this.index,
    required this.layouts,
    required this.revision,
  });
  final int index;
  final List<int> layouts;
  final int revision;

  /// Creates the retained draft owner for this tab.
  @override
  State<_TabProbe> createState() => _TabProbeState();
}

class _TabProbeState extends State<_TabProbe> {
  final controller = TextEditingController();

  /// Counts constraint-driven work that must not run in a cached tab.
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        widget.layouts[widget.index] += 1;
        return Align(
          alignment: Alignment.bottomCenter,
          child: TextField(controller: controller),
        );
      },
    );
  }

  /// Releases input state only when the tab host is removed.
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }
}
