import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/ui/rescue/DataRescueApp.dart';

/// Verifies the independent launch contract and maintenance-only request sequence.
void main() {
  test('matches only explicit maintenance entry contracts', () {
    expect(
      isDataRescueLaunch(
        arguments: const [],
        route: '/',
        uri: Uri.parse('https://operit.test/'),
      ),
      isFalse,
    );
    expect(
      isDataRescueLaunch(
        arguments: const ['--data-rescue'],
        route: '/',
        uri: Uri(),
      ),
      isTrue,
    );
    expect(
      isDataRescueLaunch(
        arguments: const [],
        route: '/data-rescue',
        uri: Uri(),
      ),
      isTrue,
    );
    expect(
      isDataRescueLaunch(
        arguments: const [],
        route: '/',
        uri: Uri.parse('https://operit.test/?mode=data-rescue'),
      ),
      isTrue,
    );
    expect(
      isDataRescueLaunch(
        arguments: const [],
        route: '/',
        uri: Uri(),
        hostRequested: true,
      ),
      isTrue,
    );
  });

  testWidgets(
    'damaged bootstrap is visible without invoking business startup',
    (tester) async {
      final host = _MaintenanceHost();
      await tester.pumpWidget(DataRescueApp(request: host.request));
      await tester.pumpAndSettle();
      expect(host.operations, ['open']);
      expect(find.textContaining('启动配置损坏'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '确认数据目录'), findsOneWidget);
      await tester.ensureVisible(find.text('确认数据目录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认数据目录'));
      await tester.pumpAndSettle();
      expect(host.operations, ['open', 'configure']);
      expect(host.selectedRoots!['runtimeRoot'], '/application/runtime');
      expect(find.text('导出全部数据'), findsOneWidget);
    },
  );

  testWidgets(
    'pending import uses journal roots without parsing repaired app state',
    (tester) async {
      final host = _MaintenanceHost(pending: true);
      await tester.pumpWidget(DataRescueApp(request: host.request));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('确认数据目录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认数据目录'));
      await tester.pumpAndSettle();
      expect(host.selectedRoots!['runtimeRoot'], '/recovery/runtime');
      expect(host.selectedRoots!['workspaceRoot'], '/recovery/workspaces');
      expect(host.selectedRoots!['cliConfigRoot'], '/recovery/cli');
      await tester.ensureVisible(find.text('完成中断的导入'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成中断的导入'));
      await tester.pumpAndSettle();
      expect(host.operations, ['open', 'configure', 'resumeRestore']);
      expect(find.textContaining('中断的导入已完成'), findsOneWidget);
    },
  );
}

class _MaintenanceHost {
  /// Creates a deterministic offline-only Host with optionally pending publication.
  _MaintenanceHost({this.pending = false});
  final bool pending;
  final operations = <String>[];
  Map<String, Object?>? selectedRoots;

  /// Rejects every request except the maintenance commands needed by the screen tests.
  Future<Object?> request(Map<String, Object?> request) async {
    final operation = request['operation']! as String;
    operations.add(operation);
    switch (operation) {
      case 'open':
        return <String, Object?>{
          'defaultRoots': {
            'runtimeRoot': '/application/runtime',
            'workspaceRoot': '/application/workspaces',
          },
          'bootstrapBase64': base64Encode(utf8.encode('{damaged bootstrap')),
          'commitPending': pending,
          if (pending)
            'recoveryRoots': {
              'runtimeRoot': '/recovery/runtime',
              'workspaceRoot': '/recovery/workspaces',
              'cliConfigRoot': '/recovery/cli',
            },
        };
      case 'configure':
        selectedRoots = Map<String, Object?>.from(request['roots']! as Map);
        return <String, Object?>{};
      case 'resumeRestore':
        return <String, Object?>{'restored': true};
      default:
        throw StateError(
          'Unexpected operation in standalone maintenance UI: $operation',
        );
    }
  }
}
