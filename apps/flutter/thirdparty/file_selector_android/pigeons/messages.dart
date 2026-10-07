// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/file_selector_api.g.dart',
    kotlinOut:
        'android/src/main/kotlin/dev/flutter/packages/file_selector_android/GeneratedFileSelectorApi.kt',
    kotlinOptions: KotlinOptions(
      package: 'dev.flutter.packages.file_selector_android',
    ),
    dartPackageName: 'file_selector_android',
  ),
)
enum FileSelectorExceptionCode {
  securityException,
  ioException,
  illegalArgumentException,
  illegalStateException,
}

class FileSelectorNativeException {
  FileSelectorNativeException({
    required this.fileSelectorExceptionCode,
    required this.message,
  });
  FileSelectorExceptionCode fileSelectorExceptionCode;
  String message;
}

/// File-backed selection metadata. Complete file contents never cross the picker channel.
class FileResponse {
  FileResponse({
    required this.path,
    this.mimeType,
    this.name,
    required this.size,
    this.fileSelectorNativeException,
  });
  String path;
  String? mimeType;
  String? name;
  int size;
  FileSelectorNativeException? fileSelectorNativeException;
}

class FileTypes {
  FileTypes({required this.mimeTypes, required this.extensions});
  List<String> mimeTypes;
  List<String> extensions;
}

@HostApi()
abstract class FileSelectorApi {
  @async
  FileResponse? openFile(String? initialDirectory, FileTypes allowedTypes);
  @async
  List<FileResponse> openFiles(
    String? initialDirectory,
    FileTypes allowedTypes,
  );
  @async
  String? getDirectoryPath(String? initialDirectory);
}
