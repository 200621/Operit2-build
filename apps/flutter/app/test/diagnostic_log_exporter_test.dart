import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:operit2/core/bridge/OperitRuntimeBridge.dart';
import 'package:operit2/core/link/CoreLinkCodec.dart';
import 'package:operit2/core/link/CoreLinkProtocol.dart';
import 'package:operit2/core/logging/DiagnosticLogExporter.dart';
import 'package:operit2/core/proxy/generated/CoreProxyClients.g.dart';

void main() {
  final exportedAt = DateTime(2026, 10, 7, 12);
  Future<DiagnosticLogExport> collect(
    String core,
    String client, {
    DateTime? at,
  }) => DiagnosticLogExporter(
    clients: GeneratedCoreProxyClients(_LogBridge(core)),
    readClientLog: () async => client,
  ).collect(exportedAt: at ?? exportedAt);

  test(
    'merges sources chronologically and preserves ties deterministically',
    () async {
      final result = await collect(
        '10:00:00.002 I/Core: second\n10:00:00.002 I/Core: third\n',
        '10:00:00.001 I/Client: first\n10:00:00.002 E/Client: last\n',
      );
      expect(_entries(result), <String>[
        '[CLIENT] 10:00:00.001 I/Client: first',
        '[CORE] 10:00:00.002 I/Core: second',
        '[CORE] 10:00:00.002 I/Core: third',
        '[CLIENT] 10:00:00.002 E/Client: last',
      ]);
      expect(result.isPartial, isFalse);
      expect(result.text, contains('Exported at: 2026-10-07T12:00:00.000'));
      expect(result.text, contains('sensitive data'));
    },
  );

  test('preserves multiline payloads, blank lines, stacks and CRLF', () async {
    final result = await collect(
      '09:00:00.000 E/Core: failed\r\ndetails\r\n\r\n'
          '09:00:00.000 E/Core: stack frame\r\n09:00:02.000 I/Core: recovered',
      '09:00:01.000 I/Client: between\n',
    );
    expect(_entries(result), <String>[
      '[CORE] 09:00:00.000 E/Core: failed',
      '[CORE] details',
      '[CORE] ',
      '[CORE] 09:00:00.000 E/Core: stack frame',
      '[CLIENT] 09:00:01.000 I/Client: between',
      '[CORE] 09:00:02.000 I/Core: recovered',
    ]);
  });

  test(
    'preserves untimestamped prefixes, unicode and verbose levels',
    () async {
      final result = await collect(
        '启动日志\n10:00:00.000 V6/Core: 核心日志',
        '10:00:00.001 V1/Client: 客户端 🚀',
      );
      expect(_entries(result), <String>[
        '[CORE] 启动日志',
        '[CORE] 10:00:00.000 V6/Core: 核心日志',
        '[CLIENT] 10:00:00.001 V1/Client: 客户端 🚀',
      ]);
      expect(utf8.decode(utf8.encode(result.text)), result.text);
    },
  );

  test('infers midnight rollovers in both sources', () async {
    final result = await collect(
      '23:59:59.000 I/Core: before\n00:00:01.000 I/Core: after\n',
      '23:59:59.500 I/Client: before\n00:00:00.500 I/Client: after\n',
      at: DateTime(2026, 10, 7, 0, 1),
    );
    expect(_entries(result), <String>[
      '[CORE] 23:59:59.000 I/Core: before',
      '[CLIENT] 23:59:59.500 I/Client: before',
      '[CLIENT] 00:00:00.500 I/Client: after',
      '[CORE] 00:00:01.000 I/Core: after',
    ]);
    expect(result.text, contains('dates are not recorded'));
  });

  test(
    'aligns a source ending before midnight with a source crossing it',
    () async {
      final result = await collect(
        '23:59:58.000 I/Core: before\n00:00:01.000 I/Core: after',
        '23:59:59.000 I/Client: last',
        at: DateTime(2026, 10, 7, 0, 1),
      );
      expect(_entries(result), <String>[
        '[CORE] 23:59:58.000 I/Core: before',
        '[CLIENT] 23:59:59.000 I/Client: last',
        '[CORE] 00:00:01.000 I/Core: after',
      ]);
    },
  );

  test('does not drop unstructured logs or malformed clocks', () async {
    final result = await collect(
      'raw core log\n99:99:99.999 I/Core: malformed',
      'raw client log',
    );
    expect(_entries(result), <String>[
      '[CORE] raw core log',
      '[CORE] 99:99:99.999 I/Core: malformed',
      '[CLIENT] raw client log',
    ]);
  });

  test('empty logs produce an empty snapshot, not a read failure', () async {
    final result = await collect('', '');
    expect(_entries(result), isEmpty);
    expect(result.text, contains('(No log entries.)'));
    expect(result.isPartial, isFalse);
    expect((await collect('', 'client log')).isPartial, isFalse);
  });

  test('Core stderr allows client-only export with a warning', () async {
    final bridge = _LogBridge('', stderr: 'Core unavailable');
    final result = await DiagnosticLogExporter(
      clients: GeneratedCoreProxyClients(bridge),
      readClientLog: () async => '10:00:00.000 I/Client: still available',
    ).collect(exportedAt: exportedAt);
    expect(result.isPartial, isTrue);
    expect(result.sourceErrors.keys, <String>['CORE']);
    expect(result.text, contains('[EXPORT WARNING] CORE:'));
    expect(result.text, contains('Core unavailable'));
    expect(_entries(result).single, contains('still available'));
    expect(bridge.request!.methodName, 'runCoreCommand');
    expect(bridge.request!.args, <String, Object?>{
      'args': <String>['log', 'show'],
    });
  });

  test('Core transport errors also allow client-only export', () async {
    final result = await DiagnosticLogExporter(
      clients: GeneratedCoreProxyClients(_LogBridge('', failCall: true)),
      readClientLog: () async => 'client log',
    ).collect(exportedAt: exportedAt);
    expect(result.sourceErrors['CORE'], contains('Transport disconnected'));
    expect(_entries(result), <String>['[CLIENT] client log']);
  });

  test('client failures retain Core logs and are reported', () async {
    final result = await DiagnosticLogExporter(
      clients: GeneratedCoreProxyClients(_LogBridge('10:00:00.000 I/Core: ok')),
      readClientLog: () async => throw StateError('Client storage unavailable'),
    ).collect(exportedAt: exportedAt);
    expect(result.isPartial, isTrue);
    expect(result.sourceErrors.keys, <String>['CLIENT']);
    expect(result.text, contains('[EXPORT WARNING] CLIENT:'));
    expect(_entries(result).single, contains('[CORE]'));
  });

  for (final response in <Object?>[null, <String, Object?>{}, 'invalid']) {
    test('rejects malformed Core response: $response', () async {
      final result = await DiagnosticLogExporter(
        clients: GeneratedCoreProxyClients(_MalformedLogBridge(response)),
        readClientLog: () async => 'client log',
      ).collect(exportedAt: exportedAt);
      expect(result.sourceErrors.keys, <String>['CORE']);
      expect(_entries(result), <String>['[CLIENT] client log']);
    });
  }

  test(
    'both read failures fail instead of claiming a successful export',
    () async {
      await expectLater(
        DiagnosticLogExporter(
          clients: GeneratedCoreProxyClients(
            _LogBridge('', stderr: 'Core offline'),
          ),
          readClientLog: () async => throw StateError('Client offline'),
        ).collect(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'both errors',
            allOf(contains('CORE:'), contains('CLIENT:')),
          ),
        ),
      );
    },
  );
}

List<String> _entries(DiagnosticLogExport result) => const LineSplitter()
    .convert(result.text)
    .where((line) => line.startsWith('[CORE] ') || line.startsWith('[CLIENT] '))
    .toList();

class _LogBridge extends OperitRuntimeBridge {
  _LogBridge(this.text, {this.stderr = '', this.failCall = false});

  final String text;
  final String stderr;
  final bool failCall;
  CoreCallRequest? request;

  @override
  Future<Uint8List> callBytes(CoreCallRequest request) async {
    this.request = request;
    if (failCall) {
      throw StateError('Transport disconnected');
    }
    return encodeCoreLink(<Object?>[
      0,
      <String, Object?>{'stdout': text, 'stderr': stderr},
    ]);
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

class _MalformedLogBridge extends _LogBridge {
  _MalformedLogBridge(this.response) : super('');

  final Object? response;

  @override
  Future<Uint8List> callBytes(CoreCallRequest request) async =>
      encodeCoreLink(<Object?>[0, response]);
}
