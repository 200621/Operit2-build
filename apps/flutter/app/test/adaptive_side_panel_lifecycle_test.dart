import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operit2/ui/common/components/AdaptiveSidePanel.dart';

void main() {
  for (final open in <bool>[false, true]) {
    testWidgets(
      'retains chat state when sidebar widths cross the panel breakpoint (open: $open)',
      (tester) async {
        tester.view.physicalSize = const Size(800, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final width = ValueNotifier<double>(744);
        final scroll = ScrollController();
        final input = TextEditingController(text: 'unsent draft');
        final counts = _LifecycleCounts();
        addTearDown(width.dispose);
        addTearDown(scroll.dispose);
        addTearDown(input.dispose);
        final content = _ChatProbe(
          counts: counts,
          scroll: scroll,
          input: input,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.centerLeft,
                child: ValueListenableBuilder<double>(
                  valueListenable: width,
                  child: content,
                  builder: (context, value, child) => SizedBox(
                    width: value,
                    child: AdaptiveSidePanel(
                      open: open,
                      onOpenChanged: (_) {},
                      panel: const ColoredBox(color: Colors.blue),
                      animate: false,
                      child: child!,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        scroll.jumpTo(480);
        await tester.pumpAndSettle();
        final contentState = tester.state(find.byType(_ChatProbe));
        final scrollPosition = scroll.position;
        final baselineBuilds = counts.built;
        for (var cycle = 0; cycle < 3; cycle++) {
          // An 800px tablet leaves 744px with the rail and 520px with the drawer.
          for (final value in <double>[
            700,
            640,
            600,
            580,
            520,
            580,
            600,
            640,
            744,
          ]) {
            width.value = value;
            await tester.pump();
            expect(tester.state(find.byType(_ChatProbe)), same(contentState));
            expect(scroll.position, same(scrollPosition));
            expect(scroll.offset, 480);
            expect(input.text, 'unsent draft');
            expect(counts.initialized, 1);
            expect(counts.disposed, 0);
            expect(counts.built, baselineBuilds);
          }
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(counts.disposed, 1);
      },
    );
  }

  testWidgets('opening the overlay preserves both content and panel state', (
    tester,
  ) async {
    final open = ValueNotifier<bool>(false);
    final counts = _LifecycleCounts();
    final scroll = ScrollController();
    final input = TextEditingController();
    addTearDown(open.dispose);
    addTearDown(scroll.dispose);
    addTearDown(input.dispose);
    final panelKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 500,
            child: ValueListenableBuilder<bool>(
              valueListenable: open,
              child: _ChatProbe(counts: counts, scroll: scroll, input: input),
              builder: (context, value, child) => AdaptiveSidePanel(
                open: value,
                onOpenChanged: (value) => open.value = value,
                panel: TextField(key: panelKey),
                child: child!,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(panelKey.currentState, isNull);
    open.value = true;
    await tester.pumpAndSettle();
    final panelState = panelKey.currentState;
    expect(panelState, isNotNull);
    for (var cycle = 0; cycle < 3; cycle++) {
      open.value = true;
      await tester.pumpAndSettle();
      expect(panelKey.currentState, same(panelState));
      open.value = false;
      await tester.pumpAndSettle();
      expect(open.value, isFalse);
      expect(panelKey.currentState, same(panelState));
      expect(counts.initialized, 1);
      expect(counts.disposed, 0);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _LifecycleCounts {
  int initialized = 0;
  int disposed = 0;
  int built = 0;
}

class _ChatProbe extends StatefulWidget {
  const _ChatProbe({
    required this.counts,
    required this.scroll,
    required this.input,
  });

  final _LifecycleCounts counts;
  final ScrollController scroll;
  final TextEditingController input;

  @override
  State<_ChatProbe> createState() => _ChatProbeState();
}

class _ChatProbeState extends State<_ChatProbe> {
  @override
  void initState() {
    super.initState();
    widget.counts.initialized++;
  }

  @override
  void dispose() {
    widget.counts.disposed++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    widget.counts.built++;
    return Column(
      children: <Widget>[
        Expanded(
          child: ListView.builder(
            controller: widget.scroll,
            itemExtent: 48,
            itemCount: 100,
            itemBuilder: (context, index) => Text('Message $index'),
          ),
        ),
        TextField(controller: widget.input),
      ],
    );
  }
}
