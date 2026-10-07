// ignore_for_file: file_names

import 'dart:convert';

import '../proxy/generated/CoreProxyClients.g.dart';
import 'ClientLogger.dart';

/// Collects the selected Core's log and this client's log without clearing either.
class DiagnosticLogExporter {
  DiagnosticLogExporter({
    required this.clients,
    Future<String> Function()? readClientLog,
  }) : _readClientLog = readClientLog ?? ClientLogger.readText;

  final GeneratedCoreProxyClients clients;
  final Future<String> Function() _readClientLog;

  /// Keeps a readable partial export when only one log source is unavailable.
  Future<DiagnosticLogExport> collect({DateTime? exportedAt}) async {
    final sources = await Future.wait(<Future<_LogSource>>[
      _readSource('CORE', _readCoreLog),
      _readSource('CLIENT', _readClientLog),
    ]);
    if (sources.every((source) => source.error != null)) {
      throw StateError(
        sources.map((source) => '${source.name}: ${source.error}').join('; '),
      );
    }
    final now = (exportedAt ?? DateTime.now()).toLocal();
    final errors = <String, String>{
      for (final source in sources)
        if (source.error != null) source.name: source.error!,
    };
    final lines = <_LogLine>[
      for (var index = 0; index < sources.length; index++)
        ..._parseLines(sources[index], index, now),
    ];
    lines.sort((left, right) {
      final timeOrder = left.time.compareTo(right.time);
      if (timeOrder != 0) {
        return timeOrder;
      }
      final sourceOrder = left.sourceIndex.compareTo(right.sourceIndex);
      return sourceOrder != 0
          ? sourceOrder
          : left.lineIndex.compareTo(right.lineIndex);
    });
    final output = StringBuffer()
      ..writeln('Operit diagnostic log')
      ..writeln('Exported at: ${now.toIso8601String()}')
      ..writeln('Sources: [CORE] selected Core; [CLIENT] this client')
      ..writeln(
        'Ordering: local HH:mm:ss.SSS; dates are not recorded. '
        'Midnight rollovers are inferred, assuming the same local clock. '
        'Ordering across time zones or gaps of whole days is approximate.',
      )
      ..writeln(
        'Warning: logs may contain sensitive data. Review before sharing.',
      );
    for (final error in errors.entries) {
      output.writeln('[EXPORT WARNING] ${error.key}: ${error.value}');
    }
    output.writeln();
    if (lines.isEmpty) {
      output.writeln('(No log entries.)');
    }
    for (final line in lines) {
      output.writeln('[${line.source}] ${line.text}');
    }
    return DiagnosticLogExport(
      text: output.toString(),
      sourceErrors: Map<String, String>.unmodifiable(errors),
    );
  }

  /// Reads the plain stdout of the existing Core log command.
  Future<String> _readCoreLog() async {
    final result = await clients.application.runCoreCommand(
      args: const <String>['log', 'show'],
    );
    if (result is! Map<Object?, Object?>) {
      throw StateError('Invalid Core log command output');
    }
    final stderr = result['stderr']?.toString().trim() ?? '';
    if (stderr.isNotEmpty) {
      throw StateError(stderr);
    }
    final stdout = result['stdout'];
    if (stdout is! String) {
      throw StateError('Missing Core log command stdout');
    }
    return stdout;
  }
}

class DiagnosticLogExport {
  const DiagnosticLogExport({required this.text, required this.sourceErrors});

  final String text;
  final Map<String, String> sourceErrors;

  bool get isPartial => sourceErrors.isNotEmpty;
}

class _LogSource {
  const _LogSource(this.name, this.text, [this.error]);

  final String name;
  final String text;
  final String? error;
}

/// Captures read errors separately so one failure does not discard the other log.
Future<_LogSource> _readSource(
  String name,
  Future<String> Function() read,
) async {
  try {
    return _LogSource(name, await read());
  } catch (error) {
    return _LogSource(name, '', error.toString());
  }
}

const int _dayMillis = 24 * 60 * 60 * 1000;
final RegExp _timestamp = RegExp(
  r'^(\d{2}):(\d{2}):(\d{2})\.(\d{3})\s+[VDIWEA](?:[1-6])?/',
);

/// Keeps unprefixed multiline payloads with their preceding timestamp.
List<_LogLine> _parseLines(_LogSource source, int sourceIndex, DateTime now) {
  final textLines = const LineSplitter().convert(source.text);
  final times = <int?>[];
  int? previousTime;
  for (final line in textLines) {
    final match = _timestamp.firstMatch(line);
    if (match != null) {
      final hour = int.parse(match[1]!);
      final minute = int.parse(match[2]!);
      final second = int.parse(match[3]!);
      if (hour < 24 && minute < 60 && second < 60) {
        previousTime =
            ((hour * 60 + minute) * 60 + second) * 1000 + int.parse(match[4]!);
      }
    }
    times.add(previousTime);
  }
  final nowMillis =
      ((now.hour * 60 + now.minute) * 60 + now.second) * 1000 + now.millisecond;
  final result = <_LogLine>[];
  var dayOffset = 0;
  int? nextTime;
  // Walk backwards so each source's most recent day aligns with the export.
  for (var index = textLines.length - 1; index >= 0; index--) {
    final time = times[index] ?? nextTime ?? nowMillis;
    if (nextTime == null) {
      if (time - nowMillis > _dayMillis ~/ 2) {
        dayOffset -= _dayMillis;
      }
    } else if (time - nextTime > _dayMillis ~/ 2) {
      dayOffset -= _dayMillis;
    }
    result.add(
      _LogLine(
        source: source.name,
        sourceIndex: sourceIndex,
        lineIndex: index,
        time: dayOffset + time,
        text: textLines[index],
      ),
    );
    nextTime = time;
  }
  return result;
}

class _LogLine {
  const _LogLine({
    required this.source,
    required this.sourceIndex,
    required this.lineIndex,
    required this.time,
    required this.text,
  });

  final String source;
  final int sourceIndex;
  final int lineIndex;
  final int time;
  final String text;
}
