// ignore_for_file: file_names

import 'package:flutter/material.dart';

import '../../../../../../l10n/generated/app_localizations.dart';
import 'WorkspaceTextDocument.dart';

/// Requires an explicit save or discard decision before closing a dirty tab.
Future<bool> confirmWorkspaceTextClose(
  BuildContext context, {
  required WorkspaceTextDocument document,
  required Future<void> Function(String text) write,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => ListenableBuilder(
      listenable: document,
      builder: (context, child) => AlertDialog(
        title: Text(l10n.workspaceUnsavedChangesTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(l10n.workspaceUnsavedChangesMessage),
            if (document.saveError != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                document.saveError.toString(),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: document.isSaving
                ? null
                : () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.workspaceDiscardChanges),
          ),
          FilledButton(
            onPressed: document.isSaving
                ? null
                : () async {
                    await document.save(write);
                    if (dialogContext.mounted && !document.isDirty) {
                      Navigator.of(dialogContext).pop(true);
                    }
                  },
            child: Text(l10n.save),
          ),
        ],
      ),
    ),
  );
  return confirmed == true;
}
