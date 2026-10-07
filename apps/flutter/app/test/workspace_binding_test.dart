import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operit2/core/bridge/OperitRuntimeBridge.dart';
import 'package:operit2/core/link/CoreLinkCodec.dart';
import 'package:operit2/core/link/CoreLinkProtocol.dart';
import 'package:operit2/data/preferences/UserPreferencesManager.dart';
import 'package:operit2/l10n/generated/app_localizations.dart';
import 'package:operit2/ui/features/chat/components/workspace/WorkspaceFileBrowserContent.dart';
import 'package:operit2/ui/features/chat/components/workspace/WorkspacePathBar.dart';
import 'package:operit2/ui/features/chat/viewmodel/ChatViewModel.dart';
import 'package:operit2/ui/features/chat/viewmodel/WorkspaceFileModels.dart';
import 'package:operit2/ui/theme/OperitTheme.dart';

Widget _app(Widget child) => OperitTheme(
  initialThemePreferenceSnapshot:
      UserPreferencesManager.defaultThemePreferenceSnapshot,
  initialThemeIsReady: false,
  unconfiguredChildEnabled: true,
  hostInteractionHostsEnabled: false,
  child: MaterialApp(
    locale: const Locale('zh'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: Scaffold(body: child),
  ),
);

void main() {
  Future<void> mountPicker(
    WidgetTester tester, {
    required Future<void> Function(String) bind,
    Future<void> Function()? pickLocal,
    List<String>? listings,
  }) async {
    await tester.pumpWidget(
      _app(
        WorkspaceFileBrowserContent(
          rootLabel: '/',
          rootRelativePath: '/',
          onListWorkspaceFiles: (path) async {
            listings?.add(path);
            return const <WorkspaceFileEntry>[
              WorkspaceFileEntry(
                name: 'project',
                path: '/project',
                relativePath: '/project',
                isDirectory: true,
                size: 0,
                lastModified: '',
              ),
            ];
          },
          onOpenFile: (_) async {},
          onSelectCurrentDirectory: bind,
          onPickLocalDirectory: pickLocal,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final bindButton = find.widgetWithText(FilledButton, '选择工作区');
  final localButton = find.widgetWithText(OutlinedButton, '选择本机文件夹');

  testWidgets('reconfirming a folder uses the shared runtime binding route', (
    tester,
  ) async {
    final bridge = _BindingBridge();
    final viewModel = ChatViewModel(bridge: bridge);
    await mountPicker(
      tester,
      bind: (path) => viewModel.bindChatToWorkspace('bound-chat', path),
    );
    await tester.tap(find.text('project'));
    await tester.pumpAndSettle();
    for (var attempt = 0; attempt < 2; attempt++) {
      await tester.tap(bindButton);
      await tester.pumpAndSettle();
    }
    expect(bridge.calls, hasLength(2));
    for (final call in bridge.calls) {
      expect(call.methodName, 'bindChatToWorkspace');
      expect((call.args as Map)['chatId'], 'bound-chat');
      expect((call.args as Map)['workspace'], '/project');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('runtime binding failure retains the selected folder for retry', (
    tester,
  ) async {
    final bridge = _BindingBridge(failFirst: true);
    final viewModel = ChatViewModel(bridge: bridge);
    await mountPicker(
      tester,
      bind: (path) => viewModel.bindChatToWorkspace('bound-chat', path),
    );
    await tester.tap(find.text('project'));
    await tester.pumpAndSettle();
    await tester.tap(bindButton);
    await tester.pumpAndSettle();
    expect(find.byType(WorkspaceFileBrowserContent), findsOneWidget);
    expect(
      find.textContaining('duplicate workspace folder name'),
      findsOneWidget,
    );
    expect(
      tester.widget<WorkspacePathBar>(find.byType(WorkspacePathBar)).path,
      '/project',
    );
    expect(tester.widget<FilledButton>(bindButton).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
    await tester.tap(bindButton);
    await tester.pumpAndSettle();
    expect(
      bridge.calls.map((call) => (call.args as Map)['workspace']),
      <String>['/project', '/project'],
    );
    expect(
      find.textContaining('duplicate workspace folder name'),
      findsNothing,
    );
  });

  testWidgets('pending binding blocks resubmission and directory navigation', (
    tester,
  ) async {
    final pending = Completer<void>();
    final listings = <String>[];
    var binds = 0;
    var localPicks = 0;
    await mountPicker(
      tester,
      listings: listings,
      bind: (_) {
        binds++;
        return pending.future;
      },
      pickLocal: () async => localPicks++,
    );
    await tester.tap(bindButton);
    await tester.pump();
    expect(tester.widget<FilledButton>(bindButton).onPressed, isNull);
    expect(tester.widget<OutlinedButton>(localButton).onPressed, isNull);
    await tester.tap(bindButton);
    await tester.tap(localButton);
    await tester.tap(find.text('project'));
    await tester.pump();
    expect(
      tester.widget<WorkspacePathBar>(find.byType(WorkspacePathBar)).path,
      '/',
    );
    expect(listings, <String>['/']);
    expect(binds, 1);
    expect(localPicks, 0);
    pending.completeError(StateError('bind failed'));
    await tester.pumpAndSettle();
    expect(find.textContaining('bind failed'), findsOneWidget);
    await tester.tap(find.text('project'));
    await tester.pumpAndSettle();
    expect(listings, <String>['/', '/project']);
    expect(find.textContaining('bind failed'), findsNothing);
  });

  testWidgets('pending binding blocks back, path editing and refresh', (
    tester,
  ) async {
    final pending = Completer<void>();
    final listings = <String>[];
    await mountPicker(tester, listings: listings, bind: (_) => pending.future);
    await tester.tap(find.text('project'));
    await tester.pumpAndSettle();
    await tester.tap(bindButton);
    await tester.pump();
    final pathBar = tester.widget<WorkspacePathBar>(
      find.byType(WorkspacePathBar),
    );
    expect(pathBar.onEditToggle, isNull);
    expect(pathBar.onSubmitted, isNull);
    expect(pathBar.onRefresh, isNull);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump();
    expect(
      tester.widget<WorkspacePathBar>(find.byType(WorkspacePathBar)).path,
      '/project',
    );
    expect(listings, <String>['/', '/project']);
    pending.complete();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(listings, <String>['/', '/project', '/']);
  });

  testWidgets('a stale path editor callback cannot change an in-flight bind', (
    tester,
  ) async {
    final pending = Completer<void>();
    final listings = <String>[];
    await mountPicker(tester, listings: listings, bind: (_) => pending.future);
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '/draft');
    final submit = tester
        .widget<WorkspacePathBar>(find.byType(WorkspacePathBar))
        .onSubmitted!;
    await tester.tap(bindButton);
    await tester.pump();
    submit('/different');
    await tester.pump();
    expect(
      tester.widget<WorkspacePathBar>(find.byType(WorkspacePathBar)).path,
      '/',
    );
    expect(listings, <String>['/']);
    pending.completeError(StateError('bind failed'));
    await tester.pumpAndSettle();
    expect(find.textContaining('bind failed'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '/draft',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(listings, <String>['/', '/draft']);
  });

  testWidgets('native folder picker failure stays visible and allows retry', (
    tester,
  ) async {
    var attempts = 0;
    await mountPicker(
      tester,
      bind: (_) async {},
      pickLocal: () async {
        attempts++;
        if (attempts == 1) throw StateError('native bind failed');
      },
    );
    await tester.tap(localButton);
    await tester.pumpAndSettle();
    expect(find.textContaining('native bind failed'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(localButton);
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.textContaining('native bind failed'), findsNothing);
  });

  testWidgets('pending native selection also blocks directory navigation', (
    tester,
  ) async {
    final pending = Completer<void>();
    var binds = 0;
    var picks = 0;
    await mountPicker(
      tester,
      bind: (_) async => binds++,
      pickLocal: () {
        picks++;
        return pending.future;
      },
    );
    await tester.tap(localButton);
    await tester.pump();
    await tester.tap(localButton);
    await tester.tap(bindButton);
    await tester.tap(find.text('project'));
    await tester.pump();
    expect(
      tester.widget<WorkspacePathBar>(find.byType(WorkspacePathBar)).path,
      '/',
    );
    expect(picks, 1);
    expect(binds, 0);
    pending.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('completion after picker disposal does not update dead state', (
    tester,
  ) async {
    final pending = Completer<void>();
    await mountPicker(tester, bind: (_) => pending.future);
    await tester.tap(bindButton);
    await tester.pump();
    await tester.pumpWidget(_app(const SizedBox()));
    pending.completeError(StateError('late binding failure'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

class _BindingBridge extends OperitRuntimeBridge {
  _BindingBridge({this.failFirst = false});

  final bool failFirst;
  final List<CoreCallRequest> calls = [];

  @override
  Future<Uint8List> callBytes(CoreCallRequest request) async {
    calls.add(request);
    if (request.methodName != 'bindChatToWorkspace') {
      throw StateError('Unexpected runtime call: ${request.methodName}');
    }
    if (failFirst && calls.length == 1) {
      return encodeCoreLink([
        1,
        'COMMAND_ERROR',
        'duplicate workspace folder name: project',
        null,
        null,
        null,
      ]);
    }
    return encodeCoreLink([0, null]);
  }

  @override
  Future<CorePushSink> push(CorePushRequest request) =>
      throw UnimplementedError();

  @override
  Future<CoreEvent> watchSnapshot(CoreWatchRequest request) =>
      throw UnimplementedError();

  @override
  Stream<CoreEvent> watchStream(CoreWatchRequest request) =>
      throw UnimplementedError();
}
