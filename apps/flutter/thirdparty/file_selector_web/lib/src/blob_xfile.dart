// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:web/web.dart';

/// Keeps the browser File, not a Dart copy of its contents or a re-fetched Blob.
class BlobXFile extends XFile {
  BlobXFile(File file)
    : _file = file,
      super(
        URL.createObjectURL(file),
        mimeType: file.type,
        name: file.name,
        length: file.size,
        lastModified: DateTime.fromMillisecondsSinceEpoch(file.lastModified),
      );

  final File _file;
  static const chunkBytes = 1024 * 1024;

  @override
  Stream<Uint8List> openRead([int? start, int? end]) async* {
    var offset = start ?? 0;
    final limit = end ?? _file.size;
    if (offset < 0 || limit < offset || limit > _file.size) {
      throw RangeError('Invalid file read range: $offset..$limit');
    }
    while (offset < limit) {
      final next = math.min(offset + chunkBytes, limit);
      final buffer = await _file.slice(offset, next).arrayBuffer().toDart;
      yield buffer.toDart.asUint8List();
      offset = next;
    }
  }
}
