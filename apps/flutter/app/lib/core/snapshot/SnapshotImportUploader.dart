// ignore_for_file: file_names

import 'dart:typed_data';

import '../host/SelectedFileInput.dart';
import '../proxy/generated/CoreProxyClients.g.dart';
import '../proxy/generated/CoreProxyModels.g.dart' as core_proxy;

/// Refers to one fully uploaded archive used by snapshot import operations.
class SnapshotImportSession {
  const SnapshotImportSession({required this.clients, required this.archive});

  final GeneratedCoreProxyClients clients;
  final core_proxy.StagedArchive archive;

  /// Returns the persisted byte length of the staged archive.
  int get byteLength => archive.byteLength;

  /// Reads raw runtime snapshot metadata from the staged archive.
  Future<core_proxy.RawSnapshotManifest> completeRaw() {
    return clients.servicesSnapshotImportManager.inspectRawSnapshot(
      archive: archive,
    );
  }

  /// Restores this uploaded raw runtime snapshot into the selected Runtime.
  Future<void> commitRaw() {
    return clients.servicesSnapshotImportManager.restoreRawSnapshot(
      archive: archive,
    );
  }

  /// Reads Operit1 snapshot metadata from the staged archive.
  Future<core_proxy.Operit1SnapshotPreview> completeOperit1() {
    return clients.servicesSnapshotImportManager.inspectOperit1Snapshot(
      archive: archive,
    );
  }

  /// Imports this uploaded Operit1 snapshot into the selected Runtime.
  Future<core_proxy.Operit1SnapshotImportResult> commitOperit1() {
    return clients.servicesSnapshotImportManager.importOperit1Snapshot(
      archive: archive,
    );
  }

  /// Removes this staged archive when no further consumer needs it.
  Future<void> discard() {
    return clients.servicesArchiveTransferManager.discardArchiveUpload(
      archiveId: archive.archiveId,
    );
  }
}

/// Uploads bounded platform file chunks through the generated archive reverse stream.
class SnapshotImportUploader {
  const SnapshotImportUploader(this.clients);

  final GeneratedCoreProxyClients clients;

  /// Creates a staged archive and uploads exactly the selected file's declared byte length.
  ///
  /// [onProgress] is called with the number of bytes already sent and the
  /// selected file's declared byte length. Keeping this callback at the
  /// uploader boundary lets settings show progress before the archive is
  /// available for inspection.
  Future<SnapshotImportSession> stage(
    SelectedFileInput file, {
    void Function(int uploadedBytes, int totalBytes)? onProgress,
  }) async {
    final byteLength = file.byteLength;
    if (byteLength == null) {
      await file.close();
      throw StateError('Snapshot imports require a known byte length');
    }
    String? archiveId;
    try {
      archiveId = await clients.servicesArchiveTransferManager
          .beginArchiveUpload(expectedByteLength: byteLength);
      var uploadedBytes = 0;

      Stream<Uint8List> trackedChunks() async* {
        await for (final chunk in file.chunks()) {
          uploadedBytes += chunk.length;
          onProgress?.call(uploadedBytes, byteLength);
          yield chunk;
        }
      }

      onProgress?.call(0, byteLength);
      await clients.servicesArchiveTransferManager.writeArchiveUpload(
        archiveId: archiveId,
        bytes: trackedChunks(),
      );
      final archive = await clients.servicesArchiveTransferManager
          .completeArchiveUpload(
            archiveId: archiveId,
            expectedByteLength: byteLength,
          );
      return SnapshotImportSession(clients: clients, archive: archive);
    } catch (error, stackTrace) {
      if (archiveId != null) {
        try {
          await clients.servicesArchiveTransferManager.discardArchiveUpload(
            archiveId: archiveId,
          );
        } catch (_) {
          /* Preserve the original upload error. */
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      await file.close();
    }
  }
}
