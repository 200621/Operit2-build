import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operit2/core/bridge/OperitRuntimeBridge.dart';
import 'package:operit2/core/link/CoreLinkCodec.dart';
import 'package:operit2/core/link/CoreLinkProtocol.dart';
import 'package:operit2/l10n/generated/app_localizations.dart';
import 'package:operit2/ui/features/settings/characters/MemoryGraphScreen.dart';

/// Verifies graph interactions and compact memory toolbar layout.
void main() {
  for (final width in [320.0, 390.0, 800.0]) {
    for (final textScale in [1.0, 1.6]) {
      testWidgets(
        'toolbar preserves search space at width $width and scale $textScale',
        (tester) async {
          await tester.binding.setSurfaceSize(Size(width, 700));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final bridge = _GraphBridge();
          await _pumpMemoryGraph(tester, bridge, textScale: textScale);

          final search = find.byType(TextField);
          expect(tester.getSize(search).width, greaterThanOrEqualTo(140));
          expect(find.text('搜索记忆'), findsOneWidget);
          expect(find.text('全部文件夹'), findsNothing);
          expect(find.text('关系模式'), findsNothing);
          expect(find.text('新建记忆'), findsNothing);
          expect(find.byTooltip('全部文件夹'), findsOneWidget);
          expect(find.byTooltip('新建记忆'), findsOneWidget);
          expect(tester.takeException(), isNull);

          await tester.tap(find.byTooltip('关系模式'));
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<IconButton>(
                  find.byWidgetPredicate(
                    (widget) =>
                        widget is IconButton && widget.tooltip == '关系模式',
                  ),
                )
                .isSelected,
            isTrue,
          );
          await tester.tap(find.byTooltip('关系模式'));
          await tester.pumpAndSettle();

          await tester.enterText(search, '测试');
          await tester.testTextInput.receiveAction(TextInputAction.search);
          await tester.pumpAndSettle();
          expect(bridge.queries, ['测试']);
          expect(tester.getSize(search).width, greaterThanOrEqualTo(140));
          await tester.tap(find.byTooltip('清空'));
          await tester.pumpAndSettle();
          expect(tester.widget<TextField>(search).controller!.text, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('long folder paths do not squeeze the search field', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const folder = '这是一个很长的记忆分类名称用于验证搜索框不会被文件夹文字挤出屏幕';
    final bridge = _GraphBridge(folders: [folder]);
    await _pumpMemoryGraph(tester, bridge);
    final search = find.byType(TextField);
    final initialWidth = tester.getSize(search).width;

    await tester.tap(find.byTooltip('全部文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(folder));
    await tester.pumpAndSettle();

    expect(find.byTooltip(folder), findsOneWidget);
    expect(find.text(folder), findsNothing);
    expect(tester.getSize(search).width, initialWidth);
    expect(initialWidth, greaterThanOrEqualTo(140));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'owner-scoped graph keeps zoom when selecting and closing details',
    (tester) async {
      final bridge = _GraphBridge();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: MemoryGraphScreen(
            bridge: bridge,
            ownerKey: 'character:alice',
            ownerName: 'Alice',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('100%'), findsOneWidget);
      await tester.tap(find.byTooltip('放大'));
      await tester.pumpAndSettle();
      expect(find.text('125%'), findsOneWidget);
      final canvas = find.byKey(const ValueKey('memory-graph-gestures'));
      await tester.tapAt(tester.getCenter(canvas));
      await tester.pumpAndSettle();
      expect(find.text('测试记忆'), findsOneWidget);
      expect(find.text('未读取到完整记忆内容'), findsOneWidget);
      expect(find.text('125%'), findsOneWidget);
      expect(bridge.calls, [
        'getMemoryGraph',
        'getAllFolderPaths',
        'findMemoriesByTitle',
      ]);
      expect(bridge.owners, everyElement('character:alice'));
      // The app bar also has a close button; close only the details card.
      await tester.tap(find.byIcon(Icons.close).first);
      await tester.pumpAndSettle();
      expect(find.text('测试记忆'), findsNothing);
      expect(find.text('125%'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

/// Pumps an owner-scoped memory graph with the requested text scale.
Future<void> _pumpMemoryGraph(
  WidgetTester tester,
  _GraphBridge bridge, {
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: MemoryGraphScreen(
        bridge: bridge,
        ownerKey: 'character:alice',
        ownerName: 'Alice',
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _GraphBridge extends OperitRuntimeBridge {
  /// Creates a graph bridge with explicit folder fixtures.
  _GraphBridge({this.folders = const []});

  final List<String> folders;
  final calls = <String>[];
  final owners = <String>[];
  final queries = <String>[];

  /// Returns graph fixtures and records owner-scoped repository calls.
  @override
  Future<Uint8List> callBytes(CoreCallRequest request) async {
    calls.add(request.methodName);
    owners.add((request.args as Map)['__core_instance_id'] as String);
    final Object value;
    switch (request.methodName) {
      case 'getMemoryGraph':
        value = {
          'nodes': [
            {'id': 'one', 'label': '测试记忆', 'color': 0xFF4CAF50, 'metadata': {}},
          ],
          'edges': [],
        };
      case 'getAllFolderPaths':
        value = folders;
      case 'searchMemories':
        queries.add((request.args as Map)['query'] as String);
        value = [];
      case 'getMemoriesByFolderPath':
      case 'findMemoriesByTitle':
        value = [];
      default:
        throw StateError('Unexpected call: ${request.methodName}');
    }
    return encodeCoreLink([0, value]);
  }

  /// Rejects push requests that are outside the graph test contract.
  @override
  Future<CorePushSink> push(CorePushRequest request) =>
      throw StateError('Unexpected push');

  /// Rejects snapshot requests that are outside the graph test contract.
  @override
  Future<CoreEvent> watchSnapshot(CoreWatchRequest request) =>
      throw StateError('Unexpected snapshot');

  /// Rejects stream requests that are outside the graph test contract.
  @override
  Stream<CoreEvent> watchStream(CoreWatchRequest request) =>
      throw StateError('Unexpected watch');
}
