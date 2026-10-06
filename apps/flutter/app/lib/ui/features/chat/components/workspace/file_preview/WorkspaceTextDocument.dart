// ignore_for_file: file_names

import 'package:flutter/foundation.dart';

/// Keeps text drafts, save state, and zoom alive when a tab moves or remounts.
class WorkspaceTextDocument extends ChangeNotifier {
  /// Creates a document from the exact text read through the workspace API.
  WorkspaceTextDocument(String text) : _text = text, _savedText = text;

  String _text;
  String _savedText;
  double _scale = 1;
  bool _saving = false;
  bool _isDirty = false;
  Object? _saveError;

  /// Returns the current editable draft.
  String get text => _text;

  /// Reads cached save status without comparing the document during zoom frames.
  bool get isDirty => _isDirty;

  /// Returns the current text zoom factor.
  double get scale => _scale;

  /// Reports whether a workspace write is in progress.
  bool get isSaving => _saving;

  /// Returns the error from the last failed write.
  Object? get saveError => _saveError;

  /// Updates the draft without changing the successfully saved snapshot.
  void updateText(String text) {
    if (_text == text) return;
    _text = text;
    _isDirty = _text != _savedText;
    notifyListeners();
  }

  /// Changes text zoom while keeping the editor within readable bounds.
  void updateScale(double scale) {
    final next = scale.clamp(0.6, 2.5);
    if (next == _scale) return;
    _scale = next;
    notifyListeners();
  }

  /// Writes one snapshot and preserves edits made while that write is pending.
  Future<void> save(Future<void> Function(String text) write) async {
    if (_saving || !isDirty) return;
    final snapshot = _text;
    _saving = true;
    _saveError = null;
    notifyListeners();
    try {
      await write(snapshot);
      _savedText = snapshot;
      _isDirty = _text != _savedText;
    } on Object catch (error) {
      _saveError = error;
    } finally {
      _saving = false;
      notifyListeners();
    }
  }
}
