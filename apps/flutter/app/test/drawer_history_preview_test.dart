import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operit2/core/bridge/OperitRuntimeBridge.dart';
import 'package:operit2/core/link/CoreLinkCodec.dart';
import 'package:operit2/core/link/CoreLinkProtocol.dart';
import 'package:operit2/core/proxy/generated/CoreProxyModels.g.dart' as core;
import 'package:operit2/data/preferences/UserPreferencesManager.dart';
import 'package:operit2/l10n/generated/app_localizations.dart';
import 'package:operit2/ui/main/components/CollapsedDrawerContent.dart';
import 'package:operit2/ui/main/components/DrawerContent.dart';
import 'package:operit2/ui/main/components/NavigationDrawerAppearance.dart';
import 'package:operit2/ui/theme/OperitTheme.dart';
import 'package:operit2/ui/main/screens/ScreenRouteRegistry.dart';

/// Verifies independent previews preserve conversation context and group actions.
void main() {
  testWidgets('each group has an independent and reversible preview', (
    tester,
  ) async {
    final bridge = _DrawerBridge();
    await _pumpDrawer(tester, bridge, <core.ChatHistoryListItem>[
      ..._histories('A', 6),
      ..._histories('B', 6),
    ]);
    expect(_visibleIds(tester), <String>[
      'A-0',
      'A-1',
      'A-2',
      'A-3',
      'B-0',
      'B-1',
      'B-2',
      'B-3',
    ]);
    expect(find.text('展开更多 2'), findsNWidgets(2));

    await tester.tap(_limitButton('A'));
    await _pumpSidebar(tester);
    expect(find.text('收起'), findsOneWidget);
    expect(find.text('A-5'), findsOneWidget);
    expect(find.text('B-4'), findsNothing);

    await tester.tap(_limitButton('A'));
    await _pumpSidebar(tester);
    expect(find.text('A-4'), findsNothing);
    expect(find.text('B-3'), findsOneWidget);
    expect(find.text('展开更多 2'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('collapsing a group never changes another group preview', (
    tester,
  ) async {
    await _pumpDrawer(tester, _DrawerBridge(), <core.ChatHistoryListItem>[
      ..._histories('A', 6),
      ..._histories('B', 6),
    ]);
    await tester.tap(_limitButton('A'));
    await _pumpSidebar(tester);
    await tester.tap(find.text('A'));
    await _pumpSidebar(tester);
    expect(find.text('A-0'), findsNothing);
    expect(find.text('B-3'), findsOneWidget);
    expect(find.text('B-4'), findsNothing);
    expect(_limitButton('A'), findsNothing);

    await tester.tap(find.text('A'));
    await _pumpSidebar(tester);
    expect(find.text('A-5'), findsOneWidget);
    expect(find.text('收起'), findsOneWidget);
    expect(find.text('B-4'), findsNothing);
    await tester.tap(_limitButton('A'));
    await _pumpSidebar(tester);
  });

  testWidgets(
    'previews keep current pinned and streaming conversations visible',
    (tester) async {
      final histories = <core.ChatHistoryListItem>[
        ..._histories('A', 5),
        _history('A', 5, pinned: true),
        _history('A', 6),
        _history('A', 7),
      ];
      await _pumpDrawer(
        tester,
        _DrawerBridge(),
        histories,
        currentChatId: 'A-4',
        streamingIds: <String>{'A-6'},
      );
      expect(_visibleIds(tester), <String>[
        'A-0',
        'A-1',
        'A-2',
        'A-3',
        'A-4',
        'A-5',
        'A-6',
      ]);
      expect(find.text('展开更多 1'), findsOneWidget);
      await tester.tap(_limitButton('A'));
      await _pumpSidebar(tester);
      expect(find.text('A-7'), findsOneWidget);
      await tester.tap(_limitButton('A'));
      await _pumpSidebar(tester);
      expect(find.text('A-7'), findsNothing);
      expect(
        tester
            .widgetList<ConversationDrawerItem>(
              find.byType(ConversationDrawerItem),
            )
            .singleWhere((item) => item.history.id == 'A-4')
            .selected,
        isTrue,
      );
      expect(find.text('A-5'), findsOneWidget);
      expect(find.text('A-6'), findsOneWidget);
    },
  );

  testWidgets(
    'expanded groups include new conversations without another click',
    (tester) async {
      final bridge = _DrawerBridge();
      await _pumpDrawer(tester, bridge, _histories('A', 6));
      await tester.tap(_limitButton('A'));
      await _pumpSidebar(tester);
      await _pumpDrawer(tester, bridge, _histories('A', 8));
      expect(find.text('A-7'), findsOneWidget);
      expect(find.text('收起'), findsOneWidget);
      expect(find.text('展开更多 2'), findsNothing);
      await tester.tap(_limitButton('A'));
      await _pumpSidebar(tester);
      expect(find.text('展开更多 4'), findsOneWidget);
    },
  );

  testWidgets('search includes hidden rows and preserves preview expansion', (
    tester,
  ) async {
    await _pumpDrawer(tester, _DrawerBridge(), _histories('A', 6));
    await tester.tap(find.byTooltip('搜索对话'));
    await _pumpSidebar(tester);
    await tester.enterText(find.byType(TextField), 'A-5');
    await _pumpSidebar(tester);
    expect(_visibleIds(tester), <String>['A-5']);
    expect(_limitButton('A'), findsNothing);
    await tester.enterText(find.byType(TextField), '');
    await _pumpSidebar(tester);
    expect(find.text('A-5'), findsNothing);
    await tester.tap(_limitButton('A'));
    await _pumpSidebar(tester);
    await tester.enterText(find.byType(TextField), 'A-5');
    await _pumpSidebar(tester);
    await tester.enterText(find.byType(TextField), '');
    await _pumpSidebar(tester);
    expect(find.text('A-5'), findsOneWidget);
    expect(find.text('收起'), findsOneWidget);
  });

  testWidgets(
    'switching the current conversation updates the collapsed preview',
    (tester) async {
      final bridge = _DrawerBridge();
      final histories = _histories('A', 7);
      await _pumpDrawer(tester, bridge, histories, currentChatId: 'A-6');
      expect(find.text('A-6'), findsOneWidget);
      expect(find.text('展开更多 2'), findsOneWidget);
      await _pumpDrawer(tester, bridge, histories, currentChatId: 'A-5');
      expect(find.text('A-6'), findsNothing);
      expect(find.text('A-5'), findsOneWidget);
      expect(find.text('展开更多 2'), findsOneWidget);
    },
  );

  testWidgets('workspace grouping uses the same independent previews', (
    tester,
  ) async {
    await _pumpDrawer(
      tester,
      _DrawerBridge(groupingMode: 'workspace'),
      <core.ChatHistoryListItem>[..._histories('A', 6), ..._histories('B', 6)],
    );
    final button = find.byKey(
      const ValueKey<String>('history-limit:group::workspace:unbound::A'),
    );
    expect(find.text('展开更多 2'), findsNWidgets(2));
    await tester.tap(button);
    await _pumpSidebar(tester);
    expect(find.text('A-5'), findsOneWidget);
    expect(find.text('B-4'), findsNothing);
    await tester.tap(button);
    await _pumpSidebar(tester);
    expect(find.text('A-5'), findsNothing);
    expect(find.text('展开更多 2'), findsNWidgets(2));
  });

  testWidgets('renaming a previewed group updates every hidden conversation', (
    tester,
  ) async {
    final bridge = _DrawerBridge();
    await _pumpDrawer(tester, bridge, _histories('A', 6));
    await _openGroupMenu(tester, 'A');
    await tester.tap(find.text('编辑名称'));
    await _pumpSidebar(tester);
    await tester.enterText(find.byType(TextField), 'Renamed');
    final l10n = AppLocalizations.of(tester.element(find.byType(AlertDialog)))!;
    await tester.tap(find.widgetWithText(FilledButton, l10n.save));
    await _pumpSidebar(tester);
    final calls = bridge.calls
        .where((call) => call.methodName == 'updateChatOrderAndGroup')
        .toList();
    expect(calls, hasLength(6));
    expect(
      ((calls.last.args as Map)['reorderedHistories'] as List).map(
        (item) => (item as Map)['group'],
      ),
      everyElement('Renamed'),
    );
    expect(find.text('Renamed'), findsOneWidget);
    expect(find.text('A-5'), findsNothing);
    expect(find.text('展开更多 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renaming an expanded group preserves its expansion', (
    tester,
  ) async {
    final bridge = _DrawerBridge();
    await _pumpDrawer(tester, bridge, _histories('A', 6));
    await tester.tap(_limitButton('A'));
    await _pumpSidebar(tester);
    await _openGroupMenu(tester, 'A');
    await tester.tap(find.text('编辑名称'));
    await _pumpSidebar(tester);
    await tester.enterText(find.byType(TextField), 'Expanded');
    final l10n = AppLocalizations.of(tester.element(find.byType(AlertDialog)))!;
    await tester.tap(find.widgetWithText(FilledButton, l10n.save));
    await _pumpSidebar(tester);
    expect(find.text('A-5'), findsOneWidget);
    expect(find.text('收起'), findsOneWidget);
    await tester.tap(_limitButton('Expanded'));
    await _pumpSidebar(tester);
    expect(find.text('A-5'), findsNothing);
  });
  testWidgets('group pinning updates hidden conversations too', (tester) async {
    final bridge = _DrawerBridge();
    await _pumpDrawer(tester, bridge, _histories('A', 6));
    expect(find.text('A-5'), findsNothing);
    await _openGroupMenu(tester, 'A');
    await tester.tap(find.text('置顶'));
    await _pumpSidebar(tester);
    expect(
      bridge.calls
          .where((call) => call.methodName == 'updateChatPinned')
          .map((call) => (call.args as Map)['chatId']),
      <String>['A-0', 'A-1', 'A-2', 'A-3', 'A-4', 'A-5'],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'group deletion uses the complete group rather than its preview',
    (tester) async {
      final bridge = _DrawerBridge();
      await _pumpDrawer(tester, bridge, _histories('A', 6));
      await _openGroupMenu(tester, 'A');
      await tester.tap(find.text('删除'));
      await _pumpSidebar(tester);
      expect(find.text('确定要删除分组“A”及其中的 6 条对话吗？'), findsOneWidget);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(AlertDialog)),
      )!;
      await tester.tap(find.widgetWithText(TextButton, l10n.delete));
      await _pumpSidebar(tester);
      expect(
        bridge.calls
            .where((call) => call.methodName == 'deleteChatHistory')
            .map((call) => (call.args as Map)['chatId']),
        <String>['A-0', 'A-1', 'A-2', 'A-3', 'A-4', 'A-5'],
      );
      expect(tester.takeException(), isNull);
    },
  );
}

/// Mounts a tall drawer so all preview rows are materialized in the test viewport.
Future<void> _pumpDrawer(
  WidgetTester tester,
  _DrawerBridge bridge,
  List<core.ChatHistoryListItem> histories, {
  String? currentChatId,
  Set<String> streamingIds = const <String>{},
}) async {
  tester.view.physicalSize = const Size(500, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    OperitTheme(
      initialThemePreferenceSnapshot:
          UserPreferencesManager.defaultThemePreferenceSnapshot,
      initialThemeIsReady: false,
      unconfiguredChildEnabled: true,
      hostInteractionHostsEnabled: false,
      child: Scaffold(
        body: DrawerContent(
          navigationEntries: const [],
          pluginEntries: const [],
          selectedRouteId: ScreenRouteRegistry.routeIdOf(
            ScreenRouteRegistry.aiChat,
          ),
          appearance: const NavigationDrawerAppearance(
            containerColor: Colors.white,
            titleColor: Colors.black,
            statusAvailableColor: Colors.blue,
            itemColor: Colors.black87,
            buttonContainerColor: Colors.white70,
            selectedContainerColor: Colors.blue,
            selectedContentColor: Colors.white,
            dividerColor: Colors.black12,
            transparentSurfaceEnabled: false,
          ),
          histories: histories,
          activeStreamingChatIds: streamingIds,
          characterGroupNamesById: const {},
          characterCardAvatarUrisByName: const {},
          currentChatId: currentChatId,
          errorMessage: null,
          loading: false,
          bridge: bridge,
          onNavigationEntrySelected: (_) {},
          onConversationActivated: () {},
        ),
      ),
    ),
  );
  await _pumpSidebar(tester);
}

/// Pumps finite sidebar transitions without waiting for streaming animations to stop.
Future<void> _pumpSidebar(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// Finds the inline preview control for a named unbound conversation group.
Finder _limitButton(String group) => find.byKey(
  ValueKey<String>('history-limit:group::character:unbound::$group'),
);

/// Reads rendered conversation IDs in their original sidebar order.
List<String> _visibleIds(WidgetTester tester) => tester
    .widgetList<ConversationDrawerItem>(find.byType(ConversationDrawerItem))
    .map((item) => item.history.id)
    .toList();

/// Reveals a group toolbar using the same hover gesture as a desktop user.
Future<void> _openGroupMenu(WidgetTester tester, String group) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: tester.getCenter(find.text(group)));
  addTearDown(mouse.removePointer);
  await _pumpSidebar(tester);
  await tester.tap(find.byTooltip('分组操作'));
  await _pumpSidebar(tester);
}

/// Creates ordered conversations for one named group.
List<core.ChatHistoryListItem> _histories(String group, int count) =>
    <core.ChatHistoryListItem>[
      for (var index = 0; index < count; index++) _history(group, index),
    ];

/// Creates a history row with explicit grouping and state flags.
core.ChatHistoryListItem _history(
  String group,
  int index, {
  bool pinned = false,
}) => core.ChatHistoryListItem(
  id: '$group-$index',
  title: '$group-$index',
  updatedAt: '2026-10-06T00:00:00Z',
  group: group,
  displayOrder: index,
  workspaceId: null,
  workspaceName: null,
  characterCardName: null,
  characterGroupId: null,
  locked: false,
  pinned: pinned,
);

class _DrawerBridge extends OperitRuntimeBridge {
  /// Configures the persisted grouping mode for the sidebar under test.
  _DrawerBridge({this.groupingMode = 'character'});

  final String groupingMode;

  /// Exposes the committed preference snapshot used by reads and watches.
  Map<String, String> get preferences => <String, String>{
    'chat_history_grouping_mode': groupingMode,
  };
  final List<CoreCallRequest> calls = <CoreCallRequest>[];

  /// Implements only preference reads and the group mutations exercised here.
  @override
  Future<Uint8List> callBytes(CoreCallRequest request) async {
    calls.add(request);
    final value = switch (request.methodName) {
      'getPreferences' => preferences,
      'updateChatOrderAndGroup' || 'updateChatPinned' => null,
      'deleteChatHistory' => true,
      _ => throw StateError('Unexpected Core call: ${request.methodName}'),
    };
    return encodeCoreLink(<Object?>[0, value]);
  }

  /// Emits the initial preference snapshot required by the grouping observer.
  @override
  Stream<CoreEvent> watchStream(CoreWatchRequest request) {
    if (request.propertyName != 'preferencesFlow') {
      throw StateError('Unexpected Core watch: ${request.propertyName}');
    }
    return Stream<CoreEvent>.value(
      CoreEvent.raw(
        requestId: request.requestId,
        target: request.target,
        propertyName: request.propertyName,
        kind: 'Snapshot',
        valueBytes: encodeCoreLink(preferences),
        decodeValue: (bytes) => decodeCoreLink<Object?>(bytes),
      ),
    );
  }

  /// Rejects pushes outside the sidebar test contract.
  @override
  Future<CorePushSink> push(CorePushRequest request) =>
      throw UnimplementedError();

  /// Rejects snapshot reads outside the sidebar test contract.
  @override
  Future<CoreEvent> watchSnapshot(CoreWatchRequest request) =>
      throw UnimplementedError();
}
