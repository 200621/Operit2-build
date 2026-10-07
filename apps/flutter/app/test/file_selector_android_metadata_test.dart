import 'dart:io';

import 'package:file_selector_android/file_selector_android.dart';
import 'package:file_selector_android/src/file_selector_api.g.dart';
import 'package:flutter_test/flutter_test.dart';

class MetadataApi extends FileSelectorApi {
  MetadataApi(this.response);
  final FileResponse response;
  @override
  Future<FileResponse?> openFile(
    String? initialDirectory,
    FileTypes allowedTypes,
  ) async => response;
  @override
  Future<List<FileResponse>> openFiles(
    String? initialDirectory,
    FileTypes allowedTypes,
  ) async => [response];
}

void main() {
  test(
    'Android picker result has no complete-content field and performs no eager read',
    () async {
      final response = FileResponse(
        path: '/not-opened/large.apk',
        name: 'large.apk',
        size: 143388128,
        mimeType: 'application/vnd.android.package-archive',
      );
      final values = response.encode() as List<Object?>;
      expect(values, hasLength(5));
      expect(values[3], 143388128);
      expect(FileResponse.decode(response.encode()), response);
      final file = await FileSelectorAndroid(
        api: MetadataApi(response),
      ).openFile();
      expect(file!.path, response.path);
      expect(file.name, 'large.apk');
      // An absent file would fail if selection still eagerly called readAsBytes.
      expect(await File(file.path).exists(), isFalse);
    },
  );

  test(
    'selected APK remains file-backed and supports bounded range reads',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'operit-picker-metadata-',
      );
      try {
        final cache = File('${directory.path}/文档.apk');
        final handle = await cache.open(mode: FileMode.write);
        await handle.truncate(
          143388128,
        ); // Sparse file; no complete in-memory payload.
        await handle.writeFrom([0, 1, 255]);
        await handle.close();
        final selector = FileSelectorAndroid(
          api: MetadataApi(
            FileResponse(path: cache.path, name: '文档.apk', size: 143388128),
          ),
        );
        final file = (await selector.openFiles()).single;
        expect(await file.length(), 143388128);
        expect(await file.openRead(0, 3).first, [0, 1, 255]);
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
