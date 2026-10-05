import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:operit2/ui/features/chat/viewmodel/ChatViewModel.dart';

/// Verifies selected file transport without depending on browser or native paths.
void main() {
  test('selected bytes retain binary content and Unicode filenames', () {
    final payload = TransferredFileAttachmentPayload(
      fileName: '文档.pdf', bytes: [0, 1, 255],
    );
    final encoded = payload.toAttachmentPath();
    expect(encoded.startsWith('transferred_file:'), isTrue);
    final json = jsonDecode(encoded.substring('transferred_file:'.length)) as Map<String, dynamic>;
    expect(json['fileName'], '文档.pdf');
    expect(json['fileSize'], 3);
    expect(base64Decode(json['base64Content'] as String), [0, 1, 255]);
    expect(json.keys, unorderedEquals(['fileName', 'fileSize', 'base64Content']));
  });

  test('empty files preserve their exact zero length', () {
    final payload = TransferredFileAttachmentPayload(fileName: 'empty', bytes: []);
    expect(payload.fileSize, 0);
    expect(payload.base64Content, '');
  });
}
