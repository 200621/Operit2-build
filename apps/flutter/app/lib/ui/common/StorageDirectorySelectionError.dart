// ignore_for_file: file_names

import 'package:flutter/services.dart';

import '../../l10n/generated/app_localizations.dart';

/// Explains why a document-provider capability cannot be used as a host path.
String storageDirectorySelectionErrorMessage(
  AppLocalizations l10n,
  Object error,
) {
  if (error is PlatformException &&
      error.code == 'UnsupportedOperationException') {
    if (error.message?.contains('com.termux.documents') ?? false) {
      return l10n.storageDirectoryTermuxUnsupported;
    }
    return l10n.storageDirectoryProviderUnsupported;
  }
  return l10n.storageDirectorySelectionFailed(
    error is PlatformException ? error.message ?? error.code : '$error',
  );
}
