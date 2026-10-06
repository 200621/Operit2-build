import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operit2/core/bridge/OperitRuntimeBridge.dart';
import 'package:operit2/core/link/CoreLinkCodec.dart';
import 'package:operit2/core/link/CoreLinkProtocol.dart';
import 'package:operit2/core/proxy/generated/CoreProxyClients.g.dart';
import 'package:operit2/l10n/generated/app_localizations.dart';
import 'package:operit2/ui/common/AppPeerDialogHost.dart';
import 'package:operit2/ui/common/SpaceJoinWidgets.dart';

Map<String, Object?> joinRequest({
  String status = 'pending',
  bool canApprove = false,
  int version = 1,
}) => {
  'requestId': 'request-1',
  'targetDeviceId': 'ios',
  'applicantDeviceId': 'mac',
  'applicantName': '我的 Mac',
  'spaceName': 'iPhone 的空间',
  'status': status,
  'createdAt': 1,
  'expiresAt': 900001,
  'canApprove': canApprove,
  'reviewerDeviceId': 'ios',
  'reviewerName': '我的 iPhone',
  'reviewerHops': 1,
  'assignmentVersion': version,
  'decisionApprove': null,
};

class JoinBridge extends OperitRuntimeBridge {
  final prompts = StreamController<CoreEvent>.broadcast();
  List<Map<String, Object?>> incoming = [], outgoing = [];
  Map<String, Object?> response = joinRequest();
  final calls = <String>[];
  Map<String, Object?>? decision;
  Completer<Uint8List>? submission, refresh;
  bool failSubmit = false, failDecision = false, failCancel = false;
  @override
  Future<Uint8List> callBytes(CoreCallRequest request) async {
    calls.add(request.methodName);
    switch (request.methodName) {
      case 'requestDeviceSpaceJoin':
        if (failSubmit) throw StateError('COMMAND_ERROR: not admitted');
        if (submission != null) return submission!.future;
        return encodeCoreLink([0, response]);
      case 'refreshDeviceSpaceJoin':
        if (refresh != null) return refresh!.future;
        return encodeCoreLink([0, response]);
      case 'outgoingDeviceSpaceJoins':
        return encodeCoreLink([0, outgoing]);
      case 'incomingDeviceSpaceJoins':
        return encodeCoreLink([0, incoming]);
      case 'decideDeviceSpaceJoin':
        decision = Map<String, Object?>.from(request.args as Map);
        if (failDecision) throw StateError('permission changed');
        incoming = [];
        response = joinRequest(
          status: decision!['approve'] == true ? 'approved' : 'rejected',
        );
        return encodeCoreLink([0, response]);
      case 'cancelDeviceSpaceJoin':
        if (failCancel) throw StateError('Cancellation transport unavailable');
        response = joinRequest(status: 'cancelled');
        return encodeCoreLink([0, response]);
      case 'deviceSpace':
        return encodeCoreLink([
          0,
          {
            'spaceId': 'target-space',
            'spaceName': 'iPhone 的空间',
            'spaceRevision': 3,
            'members': ['ios', 'mac'],
          },
        ]);
      default:
        throw StateError('Unexpected ${request.methodName}');
    }
  }

  void pairing(List<Map<String, Object?>> values) => prompts.add(
    CoreEvent.raw(
      requestId: 'pair-watch',
      target: 'core/server.runtimeRemoteLinkService',
      propertyName: 'pairingPromptsFlow',
      kind: 'Snapshot',
      valueBytes: encodeCoreLink(values),
      decodeValue: decodeCoreLink<Object?>,
    ),
  );
  @override
  Stream<CoreEvent> watchStream(CoreWatchRequest request) => prompts.stream;
  @override
  Future<CoreEvent> watchSnapshot(CoreWatchRequest request) =>
      throw UnimplementedError();
  @override
  Future<CorePushSink> push(CorePushRequest request) =>
      throw UnimplementedError();
}

void main() {
  Future<void> mount(
    WidgetTester tester,
    JoinBridge bridge, {
    bool host = false,
    bool enabled = true,
  }) async {
    final clients = GeneratedCoreProxyClients(bridge);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Builder(
          builder: (context) {
            final child = Scaffold(
              body: TextButton(
                onPressed: () => showSpaceJoinRequest(
                  context,
                  clients: clients,
                  deviceId: 'ios',
                  deviceName: '我的 iPhone',
                ),
                child: const Text('申请'),
              ),
            );
            return host
                ? AppPeerDialogHost(
                    clients: clients,
                    enabled: enabled,
                    child: child,
                  )
                : child;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> dispose(WidgetTester tester, JoinBridge bridge) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await bridge.prompts.close();
  }

  testWidgets(
    'applicant opens a real dialog immediately, before network reply',
    (tester) async {
      final bridge = JoinBridge()..submission = Completer<Uint8List>();
      await mount(tester, bridge);
      await tester.tap(find.text('申请'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('正在提交申请…'), findsOneWidget);
      bridge.submission!.complete(encodeCoreLink([0, joinRequest()]));
      await tester.pumpAndSettle();
      expect(find.text('审批人：我的 iPhone'), findsOneWidget);
      expect(find.text('等待批准'), findsOneWidget);
      expect(find.textContaining('COMMAND_ERROR'), findsNothing);
      expect(bridge.calls, isNot(contains('joinPairedDeviceSpace')));
      await dispose(tester, bridge);
    },
  );
  testWidgets(
    'submission failure remains in the dialog with retry, not a raw page error',
    (tester) async {
      final bridge = JoinBridge()..failSubmit = true;
      await mount(tester, bridge);
      await tester.tap(find.text('申请'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('提交申请'), findsOneWidget);
      expect(find.textContaining('COMMAND_ERROR'), findsOneWidget);
      bridge.failSubmit = false;
      await tester.tap(find.text('提交申请'));
      await tester.pumpAndSettle();
      expect(find.text('等待批准'), findsOneWidget);
      await dispose(tester, bridge);
    },
  );
  testWidgets(
    'receiver shows approve/reject popup automatically outside settings',
    (tester) async {
      final bridge = JoinBridge()..incoming = [joinRequest(canApprove: true)];
      await mount(tester, bridge, host: true);
      expect(find.text('空间加入申请'), findsOneWidget);
      expect(find.textContaining('我的 Mac 申请加入'), findsOneWidget);
      await tester.tap(find.text('批准'));
      await tester.pumpAndSettle();
      expect(bridge.decision, {
        'requestId': 'request-1',
        'assignmentVersion': 1,
        'approve': true,
      });
      expect(find.byType(AlertDialog), findsNothing);
      await dispose(tester, bridge);
    },
  );
  testWidgets('non-assigned/non-authorized member gets no approval popup', (
    tester,
  ) async {
    final bridge = JoinBridge()..incoming = [joinRequest(canApprove: false)];
    await mount(tester, bridge, host: true);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    await dispose(tester, bridge);
  });
  testWidgets(
    'completed pairing code closes automatically and releases approval queue',
    (tester) async {
      final bridge = JoinBridge();
      await mount(tester, bridge, host: true);
      bridge.pairing([
        {
          'pairingId': 'pair-1',
          'peerNodeId': 'mac',
          'displayName': '我的 Mac',
          'confirmationCode': '123456',
        },
      ]);
      await tester.pumpAndSettle();
      expect(find.text('123456'), findsOneWidget);
      bridge.incoming = [joinRequest(canApprove: true)];
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('空间加入申请'), findsNothing); // Still legitimately pairing.
      bridge.pairing([]);
      await tester.pumpAndSettle();
      expect(find.text('123456'), findsNothing);
      expect(find.text('空间加入申请'), findsOneWidget); // No manual OK needed.
      await tester.tap(find.text('拒绝'));
      await tester.pumpAndSettle();
      expect(bridge.decision!['approve'], false);
      await dispose(tester, bridge);
    },
  );
  testWidgets('slow outgoing refresh does not block incoming approval', (
    tester,
  ) async {
    final bridge = JoinBridge()
      ..incoming = [joinRequest(canApprove: true)]
      ..outgoing = [joinRequest()]
      ..refresh = Completer<Uint8List>();
    await mount(tester, bridge, host: true);
    expect(find.text('空间加入申请'), findsOneWidget);
    bridge.refresh!.complete(encodeCoreLink([0, joinRequest()]));
    await tester.pumpAndSettle();
    await dispose(tester, bridge);
  });
  testWidgets(
    'permission/business failure keeps approval dialog open for recovery',
    (tester) async {
      final bridge = JoinBridge()
        ..incoming = [joinRequest(canApprove: true)]
        ..failDecision = true;
      await mount(tester, bridge, host: true);
      await tester.tap(find.text('批准'));
      await tester.pumpAndSettle();
      expect(find.text('空间加入申请'), findsOneWidget);
      expect(find.textContaining('permission changed'), findsOneWidget);
      bridge.failDecision = false;
      await tester.tap(find.text('批准'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await dispose(tester, bridge);
    },
  );
  testWidgets('transferred request dismisses stale reviewer dialog', (
    tester,
  ) async {
    final bridge = JoinBridge()..incoming = [joinRequest(canApprove: true)];
    await mount(tester, bridge, host: true);
    bridge.incoming = [];
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    await dispose(tester, bridge);
  });
  testWidgets('applicant cancellation updates normal status in the dialog', (
    tester,
  ) async {
    final bridge = JoinBridge();
    await mount(tester, bridge);
    await tester.tap(find.text('申请'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消申请'));
    await tester.pumpAndSettle();
    expect(find.text('已取消'), findsOneWidget);
    await dispose(tester, bridge);
  });

  /// Verifies user cancellation is dispatched while an older background refresh is pending.
  testWidgets(
    'cancel is enabled during polling and ignores late pending responses',
    (tester) async {
      final bridge = JoinBridge();
      await mount(tester, bridge);
      await tester.tap(find.text('申请'));
      await tester.pumpAndSettle();
      bridge.refresh = Completer<Uint8List>();
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(bridge.calls, contains('refreshDeviceSpaceJoin'));
      await tester.tap(find.text('取消申请'));
      await tester.pumpAndSettle();
      expect(bridge.calls, contains('cancelDeviceSpaceJoin'));
      expect(find.text('已取消'), findsOneWidget);
      bridge.refresh!.complete(encodeCoreLink([0, joinRequest()]));
      await tester.pumpAndSettle();
      expect(find.text('已取消'), findsOneWidget);
      expect(find.text('等待批准'), findsNothing);
      await dispose(tester, bridge);
    },
  );

  /// Verifies an unacknowledged local submission is not presented as an offline reviewer.
  testWidgets(
    'failed unassigned submission shows the real failure and remains cancellable',
    (tester) async {
      final pending = joinRequest()
        ..['reviewerDeviceId'] = null
        ..['reviewerName'] = null
        ..['reviewerHops'] = null;
      final bridge = JoinBridge()
        ..failSubmit = true
        ..outgoing = [pending];
      await mount(tester, bridge);
      await tester.tap(find.text('申请'));
      await tester.pumpAndSettle();
      expect(find.text('等待有审批权限的设备上线'), findsNothing);
      expect(find.textContaining('COMMAND_ERROR'), findsOneWidget);
      await tester.tap(find.text('取消申请'));
      await tester.pumpAndSettle();
      expect(find.text('已取消'), findsOneWidget);
      await dispose(tester, bridge);
    },
  );

  /// Verifies cancellation errors remain visible and a second click sends a new cancellation.
  testWidgets('failed cancellation shows its cause and permits retry', (
    tester,
  ) async {
    final bridge = JoinBridge()..failCancel = true;
    await mount(tester, bridge);
    await tester.tap(find.text('申请'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消申请'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Cancellation transport unavailable'),
      findsOneWidget,
    );
    bridge.failCancel = false;
    await tester.tap(find.text('取消申请'));
    await tester.pumpAndSettle();
    expect(find.text('已取消'), findsOneWidget);
    await dispose(tester, bridge);
  });

  testWidgets('approved applicant refresh closes dialog with adopted space', (
    tester,
  ) async {
    final bridge = JoinBridge();
    await mount(tester, bridge);
    await tester.tap(find.text('申请'));
    await tester.pumpAndSettle();
    bridge.response = joinRequest(status: 'joined');
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(bridge.calls, contains('deviceSpace'));
    await dispose(tester, bridge);
  });
}
