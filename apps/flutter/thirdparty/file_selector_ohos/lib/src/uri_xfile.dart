// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/services.dart';

/// Metadata-only selection; native URI descriptors exist only during a read.
class UriXFile extends XFile {
  UriXFile(String path, {String? name, String? mimeType, required int length})
      : _name = name ?? Uri.parse(path).pathSegments.last,
        _length = length,
        super(path, mimeType: mimeType);

  static const _channel = MethodChannel(
    'dev.flutter.packages.file_selector_ohos/input',
  );
  static const chunkBytes = 1024 * 1024;
  final String _name;
  final int _length;

  @override
  String get name => _name;

  @override
  Future<int> length() async => _length;

  @override
  Stream<Uint8List> openRead([int? start, int? end]) async* {
    final offset = start ?? 0;
    final limit = end ?? _length;
    if (offset < 0 || limit < offset || limit > _length) {
      throw RangeError('Invalid file read range: $offset..$limit');
    }
    if (offset == limit) return;
    final token = await _channel.invokeMethod<String>('open', {
      'path': path,
      'start': offset,
    });
    if (token == null) {
      throw StateError('Native document input returned no token');
    }
    try {
      var remaining = limit - offset;
      while (remaining > 0) {
        final maxBytes = math.min(chunkBytes, remaining);
        final bytes = await _channel.invokeMethod<Uint8List>('readChunk', {
          'token': token,
          'maxBytes': maxBytes,
        });
        if (bytes == null || bytes.length > maxBytes) {
          throw StateError('Native document input returned an invalid chunk');
        }
        if (bytes.isEmpty) {
          throw StateError('Native document ended before its declared length');
        }
        remaining -= bytes.length;
        yield bytes;
      }
    } finally {
      await _channel.invokeMethod<void>('close', {'token': token});
    }
  }

  @override
  Future<Uint8List> readAsBytes() async {
    final builder = BytesBuilder(copy: false);
    await for (final bytes in openRead()) {
      builder.add(bytes);
    }
    return builder.takeBytes();
  }

  @override
  Future<String> readAsString({Encoding encoding = utf8}) async =>
      encoding.decode(await readAsBytes());
}
