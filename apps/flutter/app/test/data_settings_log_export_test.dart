import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operit2/core/bridge/OperitRuntimeBridge.dart';
import 'package:operit2/core/link/CoreLinkCodec.dart';
import 'package:operit2/core/link/CoreLinkProtocol.dart';
import 'package:operit2/core/logging/DiagnosticLogExporter.dart';
import 'package:operit2/core/proxy/generated/CoreProxyClients.g.dart';
import 'package:operit2/data/preferences/UserPreferencesManager.dart';
import 'package:operit2/l10n/generated/app_localizations.dart';
import 'package:operit2/ui/features/settings/data/DataSettingsPanel.dart';
import 'package:operit2/ui/theme/OperitTheme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final originalFileSelector = FileSelectorPlatform.instance;

  tearDown(() => FileSelectorPlatform.instance = originalFileSelector);

  testWidgets('exports both logs even when the overview cannot load', (
    tester,
  ) async {
    final saver = _LogSavePlatform();
    FileSelectorPlatform.instance = saver;
    final l10n = await _pumpPanel(tester, _LogBridge());
    expect(find.text(l10n.settingsDataLogsSection), findsOneWidget);
    await tester.tap(find.text(l10n.settingsDataExportLogs));
    await tester.pumpAndSettle();
    expect(saver.text, contains('[CORE] 10:00:00.000 I/Core: core log'));
    expect(saver.text, contains('[CLIENT] '));
    expect(saver.text, contains('客户端诊断测试 🚀'));
    expect(saver.name, startsWith('operit-diagnostics-'));
    expect(saver.name, endsWith('.log'));
    expect(saver.mimeType, 'text/plain');
    expect(saver.extensions, <String>['log', 'txt']);
    expect(
      find.text(l10n.savedTo('/selected/diagnostics.log')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelled save restores the button without a success message', (
    tester,
  ) async {
    final saver = _LogSavePlatform(cancel: true);
    FileSelectorPlatform.instance = saver;
    final l10n = await _pumpPanel(tester, _LogBridge());
    await tester.tap(find.text(l10n.settingsDataExportLogs));
    await tester.pumpAndSettle();
    expect(saver.calls, 1);
    expect(find.byType(SnackBar), findsNothing);
    expect(_exportButton(tester, l10n).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a partial export is saved and visibly marked as partial', (
    tester,
  ) async {
    final saver = _LogSavePlatform();
    FileSelectorPlatform.instance = saver;
    final l10n = await _pumpPanel(
      tester,
      _LogBridge(stderr: 'Core disconnected'),
    );
    await tester.tap(find.text(l10n.settingsDataExportLogs));
    await tester.pumpAndSettle();
    expect(saver.text, contains('[EXPORT WARNING] CORE:'));
    expect(saver.text, contains('Core disconnected'));
    expect(saver.text, contains('客户端诊断测试 🚀'));
    expect(
      find.text(
        l10n.settingsDataLogsExportPartial('/selected/diagnostics.log'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('save errors show a localized failure and restore the button', (
    tester,
  ) async {
    FileSelectorPlatform.instance = _LogSavePlatform(failSave: true);
    final l10n = await _pumpPanel(tester, _LogBridge());
    await tester.tap(find.text(l10n.settingsDataExportLogs));
    await tester.pumpAndSettle();
    expect(
      find.text(l10n.settingsDataLogsExportError('Bad state: Save failed')),
      findsOneWidget,
    );
    expect(_exportButton(tester, l10n).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the export button is disabled while collection is pending', (
    tester,
  ) async {
    final pending = Completer<Object?>();
    final saver = _LogSavePlatform();
    FileSelectorPlatform.instance = saver;
    final l10n = await _pumpPanel(tester, _LogBridge(pending: pending.future));
    await tester.tap(find.text(l10n.settingsDataExportLogs));
    await tester.pump();
    final button = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text(l10n.settingsDataLogsExporting),
        matching: find.byType(FilledButton),
      ),
    );
    expect(button.onPressed, isNull);
    expect(saver.calls, 0);
    pending.complete(<String, Object?>{'stdout': 'core log', 'stderr': ''});
    await tester.pumpAndSettle();
    expect(saver.calls, 1);
    expect(_exportButton(tester, l10n).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow settings keep the export action accessible', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(340, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final l10n = await _pumpPanel(tester, _LogBridge());
    expect(_exportButton(tester, l10n).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });
}

Future<AppLocalizations> _pumpPanel(
  WidgetTester tester,
  _LogBridge bridge,
) async {
  await tester.pumpWidget(
    OperitTheme(
      initialThemePreferenceSnapshot:
          UserPreferencesManager.defaultThemePreferenceSnapshot,
      initialThemeIsReady: false,
      unconfiguredChildEnabled: true,
      hostInteractionHostsEnabled: false,
      child: Scaffold(
        body: DataSettingsPanel(
          clients: GeneratedCoreProxyClients(bridge),
          diagnosticLogExporter: DiagnosticLogExporter(
            clients: GeneratedCoreProxyClients(bridge),
            readClientLog: () async => '10:00:00.001 I/Client: 客户端诊断测试 🚀',
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return AppLocalizations.of(tester.element(find.byType(DataSettingsPanel)))!;
}

FilledButton _exportButton(WidgetTester tester, AppLocalizations l10n) =>
    tester.widget<FilledButton>(
      find.ancestor(
        of: find.text(l10n.settingsDataExportLogs),
        matching: find.byType(FilledButton),
      ),
    );

class _LogSavePlatform extends FileSelectorPlatform {
  _LogSavePlatform({this.cancel = false, this.failSave = false});

  final bool cancel;
  final bool failSave;
  int calls = 0;
  String? text;
  String? name;
  String? mimeType;
  List<String>? extensions;

  @override
  Future<FileSaveLocation?> saveFile({
    required XFile file,
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async {
    calls++;
    name = options.suggestedName;
    mimeType = file.mimeType;
    extensions = acceptedTypeGroups?.single.extensions;
    if (failSave) {
      throw StateError('Save failed');
    }
    if (cancel) {
      return null;
    }
    text = utf8.decode(await file.readAsBytes());
    return FileSaveLocation('/selected/diagnostics.log');
  }
}

class _LogBridge extends OperitRuntimeBridge {
  _LogBridge({this.stderr = '', this.pending});

  final String stderr;
  final Future<Object?>? pending;

  @override
  Future<Uint8List> callBytes(CoreCallRequest request) async {
    expect(request.methodName, 'runCoreCommand');
    final response = pending == null
        ? <String, Object?>{
            'stdout': '10:00:00.000 I/Core: core log\n',
            'stderr': stderr,
          }
        : await pending;
    return encodeCoreLink(<Object?>[0, response]);
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
