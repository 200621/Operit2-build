import 'dart:typed_data';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operit2/core/host/FileSaveService.dart';

/// Verifies that snapshot file references never pass through whole-file byte saving.
void main() {
  final original = FileSelectorPlatform.instance;

  /// Restores the registered output implementation after each test.
  tearDown(() => FileSelectorPlatform.instance = original);

  /// Exercises the portable file-reference save path without any byte materialization.
  test('generated host file is saved by reference', () async {
    final platform = _SaveLocationPlatform('/selected/snapshot.zip');
    FileSelectorPlatform.instance = platform;
    final file = _ReferenceOnlyFile();
    final result = await FileSaveService.saveGeneratedFile(
      generate: () async => file,
      name: 'snapshot.zip',
      acceptedTypeGroups: const <XTypeGroup>[],
    );
    expect(result, '/selected/snapshot.zip');
    expect(file.savedTo, '/selected/snapshot.zip');
    expect(platform.suggestedName, 'snapshot.zip');
    expect(file.byteReads, 0);
  });

  /// Keeps cancellation explicit and does not switch to a byte save operation.
  test('cancelled save does not write the file', () async {
    FileSelectorPlatform.instance = _SaveLocationPlatform(null);
    final file = _ReferenceOnlyFile();
    final result = await FileSaveService.saveGeneratedFile(
      generate: () async => file,
      name: 'snapshot.zip',
      acceptedTypeGroups: const <XTypeGroup>[],
    );
    expect(result, isNull);
    expect(file.savedTo, isNull);
    expect(file.byteReads, 0);
  });

  /// Propagates output failures without repeating generation or reading all bytes.
  test('file copy failure is propagated', () async {
    FileSelectorPlatform.instance = _SaveLocationPlatform(
      '/selected/snapshot.zip',
    );
    final file = _ReferenceOnlyFile(failSave: true);
    var generated = 0;
    await expectLater(
      FileSaveService.saveGeneratedFile(
        generate: () async {
          generated += 1;
          return file;
        },
        name: 'snapshot.zip',
        acceptedTypeGroups: const <XTypeGroup>[],
      ),
      throwsStateError,
    );
    expect(generated, 1);
    expect(file.byteReads, 0);
  });
}

/// Supplies a deterministic destination while retaining the production file-reference implementation.
class _SaveLocationPlatform extends FileSelectorPlatform {
  /// Records the selected output path used by this test implementation.
  _SaveLocationPlatform(this.path);

  final String? path;
  String? suggestedName;

  /// Returns the selected destination or an explicit user cancellation.
  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async {
    suggestedName = options.suggestedName;
    return path == null ? null : FileSaveLocation(path!);
  }
}

/// Models a large host file whose bytes must not be read into Flutter.
class _ReferenceOnlyFile extends XFile {
  /// Creates a reference-only file with an optional explicit output failure.
  _ReferenceOnlyFile({this.failSave = false}) : super('/host/snapshot.sealed');

  final bool failSave;
  int byteReads = 0;
  String? savedTo;

  /// Rejects accidental whole-file byte materialization.
  @override
  Future<Uint8List> readAsBytes() async {
    byteReads += 1;
    throw StateError('Snapshot bytes must remain in host storage');
  }

  /// Records the file-backed copy without reading its contents.
  @override
  Future<void> saveTo(String path) async {
    if (failSave) {
      throw StateError('Output write failed');
    }
    savedTo = path;
  }
}
