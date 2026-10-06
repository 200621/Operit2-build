import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operit2/ui/common/components/RetainedPage.dart';
import 'package:operit2/ui/common/components/PageActivityMixin.dart';

/// Verifies that cached pages preserve state without doing hidden UI work.
void main() {
  testWidgets('sleeping pages skip builds, layouts, paints, and tickers', (
    tester,
  ) async {
    final key = GlobalKey<_ProbeState>();
    final counts = _Counts();
    final signal = ValueNotifier<int>(0);
    addTearDown(signal.dispose);
    await _pump(tester, key, counts, signal);
    final state = key.currentState!;
    state.controller.text = 'retained draft';
    state.focusNode.requestFocus();
    await tester.pump();
    expect(state.focusNode.hasFocus, isTrue);
    await _pump(tester, key, counts, signal, active: false);
    await tester.pump();
    final before = counts.snapshot;
    final ticks = counts.ticks;
    expect(counts.renders.every((r) => !r.attached), isTrue);
    for (var i = 1; i <= 5; i += 1) {
      signal.value = i;
      state.increment();
      for (final render in counts.renders) {
        render.markNeedsLayout();
        render.markNeedsPaint();
      }
      await _pump(
        tester,
        key,
        counts,
        signal,
        active: false,
        height: 720 - i * 50,
        inset: i * 50,
        revision: i,
        dark: true,
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(counts.snapshot, before);
      expect(counts.ticks, ticks);
      expect(key.currentState, same(state));
      expect(tester.takeException(), isNull);
    }
    expect(state.focusNode.hasFocus, isFalse);
    expect(find.byType(TextField), findsNothing);
    expect(state.widget.revision, 0);
    await _pump(
      tester,
      key,
      counts,
      signal,
      height: 470,
      inset: 250,
      revision: 5,
      dark: true,
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(key.currentState, same(state));
    expect(state.controller.text, 'retained draft');
    expect(state.value, 5);
    expect(state.lastInset, 250);
    expect(state.lastSignal, 5);
    expect(state.lastBrightness, Brightness.dark);
    expect(state.widget.revision, 5);
    expect(counts.layouts, greaterThan(before[1]));
    expect(counts.ticks, greaterThan(ticks));
    expect(counts.renders.every((r) => r.attached), isTrue);
    expect(tester.takeException(), isNull);
    await _pump(tester, key, counts, signal, active: false);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(counts.disposals, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('nested sleeping pages stop async UI work and resume updates', (
    tester,
  ) async {
    final outer = ValueNotifier<bool>(true);
    final inner = ValueNotifier<bool>(true);
    final signal = ValueNotifier<int>(0);
    final key = GlobalKey<_AsyncProbeState>();
    addTearDown(outer.dispose);
    addTearDown(inner.dispose);
    addTearDown(signal.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: outer,
          builder: (context, outerActive, _) => RetainedPage(
            active: outerActive,
            child: ValueListenableBuilder<bool>(
              valueListenable: inner,
              builder: (context, innerActive, _) => RetainedPage(
                active: innerActive,
                child: _AsyncProbe(key: key, signal: signal),
              ),
            ),
          ),
        ),
      ),
    );
    final state = key.currentState!;
    await tester.pump(const Duration(milliseconds: 60));
    expect(state.polls, greaterThan(0));
    var expectedValue = 0;
    for (var cycle = 0; cycle < 3; cycle += 1) {
      outer.value = false;
      await tester.pump();
      await tester.pump();
      expect(state.isPageActive, isFalse);
      final builds = state.builds;
      final polls = state.polls;
      signal.value += 1;
      state.increment();
      expectedValue += 1;
      await tester.pump(const Duration(seconds: 2));
      expect(state.builds, builds);
      expect(state.polls, polls);
      expect(find.text('Async page'), findsNothing);
      expect(key.currentState, same(state));
      outer.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(state.isPageActive, isTrue);
      expect(state.polls, greaterThan(polls));
      expect(state.displayedSignal, signal.value);
      expect(state.displayedValue, expectedValue);
      final awakeBuilds = state.builds;
      state.increment();
      expectedValue += 1;
      await tester.pump();
      expect(state.builds, greaterThan(awakeBuilds));
      expect(state.displayedValue, expectedValue);
    }
    inner.value = false;
    await tester.pump();
    await tester.pump();
    expect(state.isPageActive, isFalse);
    final polls = state.polls;
    await tester.pump(const Duration(seconds: 2));
    expect(state.polls, polls);
    inner.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(state.isPageActive, isTrue);
    expect(state.polls, greaterThan(polls));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cached pages are excluded from semantics and recover their scroll position',
    (tester) async {
      final semantics = tester.ensureSemantics();

      final active = ValueNotifier<bool>(true);
      final scroll = ScrollController();
      addTearDown(active.dispose);
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            height: 300,
            child: ValueListenableBuilder<bool>(
              valueListenable: active,
              child: ListView.builder(
                controller: scroll,
                itemExtent: 50,
                itemCount: 50,
                itemBuilder: (context, index) => Text('Cached item $index'),
              ),
              builder: (context, visible, child) =>
                  RetainedPage(active: visible, child: child!),
            ),
          ),
        ),
      );
      scroll.jumpTo(350);
      await tester.pump();
      final position = scroll.position;
      active.value = false;
      await tester.pump();
      await tester.pump();
      expect(find.byType(ListView), findsNothing);
      expect(
        tester
            .binding
            .renderViews
            .single
            .owner!
            .semanticsOwner!
            .rootSemanticsNode!
            .toStringDeep(),
        isNot(contains('Cached item')),
      );
      active.value = true;
      await tester.pump();
      expect(scroll.position, same(position));
      expect(scroll.offset, 350);
      semantics.dispose();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'sleeping pages do not leave ink geometry in live ancestor materials',
    (tester) async {
      final active = ValueNotifier<bool>(true);
      addTearDown(active.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: active,
              child: Center(
                child: InkWell(onTap: () {}, child: const Text('Cached ink')),
              ),
              builder: (context, visible, child) =>
                  RetainedPage(active: visible, child: child!),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Cached ink'));
      await tester.pump(const Duration(milliseconds: 30));
      active.value = false;
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Cached ink'), findsNothing);
      expect(tester.takeException(), isNull);
      active.value = true;
      await tester.pumpAndSettle();
      expect(find.text('Cached ink'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('removing the last page restores the original build scheduler', (
    tester,
  ) async {
    final original = tester.binding.buildOwner!.onBuildScheduled;
    await tester.pumpWidget(
      const MaterialApp(
        home: RetainedPage(
          active: true,
          child: RetainedPage(active: true, child: Text('Nested')),
        ),
      ),
    );
    expect(tester.binding.buildOwner!.onBuildScheduled, isNot(original));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.binding.buildOwner!.onBuildScheduled, original);
    expect(tester.takeException(), isNull);
  });

  testWidgets('initially inactive pages mount only when activated', (
    tester,
  ) async {
    final key = GlobalKey<_ProbeState>();
    final counts = _Counts();
    final signal = ValueNotifier<int>(0);
    addTearDown(signal.dispose);
    await _pump(tester, key, counts, signal, active: false);
    expect(key.currentState, isNull);
    await _pump(tester, key, counts, signal);
    expect(key.currentState, isNotNull);
    expect(tester.takeException(), isNull);
  });
}

/// Changes viewport constraints and inherited values around a retained page.
Future<void> _pump(
  WidgetTester tester,
  GlobalKey<_ProbeState> key,
  _Counts counts,
  ValueNotifier<int> signal, {
  bool active = true,
  double height = 720,
  double inset = 0,
  int revision = 0,
  bool dark = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? ThemeData.dark() : ThemeData.light(),
      themeAnimationDuration: Duration.zero,
      home: MediaQuery(
        data: MediaQueryData(viewInsets: EdgeInsets.only(bottom: inset)),
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 360,
            height: height,
            child: RetainedPage(
              active: active,
              child: _Probe(
                key: key,
                counts: counts,
                signal: signal,
                revision: revision,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _Counts {
  int builds = 0;
  int layouts = 0;
  int paints = 0;
  int ticks = 0;
  int disposals = 0;
  final List<_RenderProbe> renders = <_RenderProbe>[];

  /// Copies the UI work counters for an inactivity assertion.
  List<int> get snapshot => <int>[builds, layouts, paints];
}

class _Probe extends StatefulWidget {
  /// Creates a probe whose state and render work remain observable.
  const _Probe({
    super.key,
    required this.counts,
    required this.signal,
    required this.revision,
  });
  final _Counts counts;
  final ValueNotifier<int> signal;
  final int revision;

  /// Creates retained input, animation, and local counter state.
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> with SingleTickerProviderStateMixin {
  final controller = TextEditingController();
  final focusNode = FocusNode();
  late final AnimationController animation;
  int value = 0;
  double lastInset = 0;
  int lastSignal = 0;
  Brightness? lastBrightness;

  /// Starts a repeating animation that must be muted while hidden.
  @override
  void initState() {
    super.initState();
    animation = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..addListener(_tick);
    animation.repeat();
  }

  /// Counts ticker work separately from widget rebuilding.
  void _tick() {
    widget.counts.ticks += 1;
  }

  /// Marks retained state dirty without changing its identity.
  void increment() {
    setState(() => value += 1);
  }

  /// Exercises inherited dependencies and a nested layout build scope.
  @override
  Widget build(BuildContext context) {
    widget.counts.builds += 1;
    lastInset = MediaQuery.viewInsetsOf(context).bottom;
    lastBrightness = Theme.of(context).brightness;
    return Material(
      child: LayoutBuilder(
        builder: (context, constraints) {
          widget.counts.builds += 1;
          return ValueListenableBuilder<int>(
            valueListenable: widget.signal,
            builder: (context, value, _) {
              lastSignal = value;
              widget.counts.builds += 1;
              return _RenderProbeWidget(
                counts: widget.counts,
                child: RepaintBoundary(
                  child: Column(
                    children: <Widget>[
                      TextField(controller: controller, focusNode: focusNode),
                      Text('$value / ${widget.revision}'),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  /// Disposes the retained resources only when the page is removed.
  @override
  void dispose() {
    widget.counts.disposals += 1;
    animation.dispose();
    focusNode.dispose();
    controller.dispose();
    super.dispose();
  }
}

class _RenderProbeWidget extends SingleChildRenderObjectWidget {
  /// Creates a render counter beneath a nested layout build scope.
  const _RenderProbeWidget({required this.counts, required super.child});
  final _Counts counts;

  /// Exposes the render object for independent dirty-work tests.
  @override
  _RenderProbe createRenderObject(BuildContext context) {
    final render = _RenderProbe(counts);
    counts.renders.add(render);
    return render;
  }
}

class _RenderProbe extends RenderProxyBox {
  /// Creates an independently repaintable render probe.
  _RenderProbe(this.counts);
  final _Counts counts;

  /// Allows paint invalidations to be scheduled independently of ancestors.
  @override
  bool get isRepaintBoundary => true;

  /// Counts actual child layout passes.
  @override
  void performLayout() {
    counts.layouts += 1;
    super.performLayout();
  }

  /// Counts actual child paint passes.
  @override
  void paint(PaintingContext context, Offset offset) {
    counts.paints += 1;
    super.paint(context, offset);
  }
}

class _AsyncProbe extends StatefulWidget {
  /// Creates a page that owns periodic presentation work and direct dirty builds.
  const _AsyncProbe({super.key, required this.signal});
  final ValueNotifier<int> signal;

  /// Creates the activity-aware presentation task owner.
  @override
  State<_AsyncProbe> createState() => _AsyncProbeState();
}

class _AsyncProbeState extends State<_AsyncProbe>
    with PageActivityMixin<_AsyncProbe> {
  Timer? _timer;
  int polls = 0;
  int builds = 0;
  int value = 0;
  int displayedValue = 0;
  int displayedSignal = 0;

  /// Starts and stops a page-owned periodic task synchronously with activity.
  @override
  void onPageActivityChanged(bool active) {
    _timer?.cancel();
    _timer = null;
    if (active) {
      _timer = Timer.periodic(const Duration(milliseconds: 20), _poll);
    }
  }

  /// Counts presentation work that must stop throughout cached inactivity.
  void _poll(Timer timer) {
    polls += 1;
  }

  /// Exercises a dirty element outside a nested LayoutBuilder scope.
  void increment() {
    setState(() => value += 1);
  }

  /// Records the latest state and notifier snapshot actually displayed.
  @override
  Widget build(BuildContext context) {
    builds += 1;
    displayedValue = value;
    return ValueListenableBuilder<int>(
      valueListenable: widget.signal,
      builder: (context, signal, _) {
        displayedSignal = signal;
        return const Text('Async page');
      },
    );
  }

  /// Cancels presentation polling when the retained page is removed.
  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
