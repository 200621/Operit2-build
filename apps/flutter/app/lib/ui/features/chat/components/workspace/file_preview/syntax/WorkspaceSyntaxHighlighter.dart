// ignore_for_file: file_names

import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'WorkspaceSyntaxLanguage.dart';
import 'WorkspaceSyntaxLexer.dart';
import 'WorkspaceSyntaxPalette.dart';
import 'WorkspaceSyntaxToken.dart';

/// Attaches lightweight lexical state to a persistent source-line identity.
class WorkspaceSyntaxLine {
  /// Preserves source text independently from evictable visible token intervals.
  WorkspaceSyntaxLine(this.content);

  final String content;
  WorkspaceSyntaxState? syntaxStart;
  WorkspaceSyntaxState? syntaxEnd;
}

/// Indexes multiline context while caching colored tokens only for viewed lines.
class WorkspaceSyntaxHighlighter {
  /// Starts in the explicit plain-text format without doing source-wide lexing.
  WorkspaceSyntaxHighlighter();

  WorkspaceSyntaxLanguage _language = WorkspaceSyntaxLanguage.plainText;
  final LinkedHashMap<WorkspaceSyntaxLine, List<WorkspaceSyntaxToken>> _tokens =
      LinkedHashMap();
  static final Map<WorkspaceSyntaxLanguage, WorkspaceSyntaxLexer> _lexers = {};
  int debugStateScans = 0;
  int debugTokenScans = 0;

  /// Exposes the selected grammar to render inspection and regression tests.
  WorkspaceSyntaxLanguage get language => _language;

  /// Reports only retained tokenized lines, never total indexed source lines.
  int get cachedLines => _tokens.length;

  /// Resolves one shared compiled lexer for the explicitly selected grammar.
  WorkspaceSyntaxLexer get _lexer =>
      _lexers.putIfAbsent(_language, () => WorkspaceSyntaxLexer(_language));

  /// Reindexes lexical boundaries when a file's declared language changes.
  bool configure(
    WorkspaceSyntaxLanguage language,
    List<WorkspaceSyntaxLine> lines,
  ) {
    if (_language == language) return false;
    _language = language;
    _tokens.clear();
    for (final line in lines) {
      line.syntaxStart = null;
      line.syntaxEnd = null;
    }
    synchronize(lines, through: lines.length);
    return true;
  }

  /// Propagates edited lexical state only until the unchanged suffix converges.
  void synchronize(
    List<WorkspaceSyntaxLine> lines, {
    int first = 0,
    required int through,
    void Function(WorkspaceSyntaxLine line)? onInvalidated,
  }) {
    if (_language == WorkspaceSyntaxLanguage.plainText ||
        first >= lines.length) {
      return;
    }
    var state = first == 0
        ? WorkspaceSyntaxState.empty
        : lines[first - 1].syntaxEnd!;
    for (var i = first; i < lines.length; i++) {
      final line = lines[i];
      if (i >= through && line.syntaxStart == state) break;
      if (line.syntaxStart != state || line.syntaxEnd == null) {
        _tokens.remove(line);
        onInvalidated?.call(line);
      }
      line.syntaxStart = state;
      state = _lexer.scan(line.content, state, tokens: false).state;
      line.syntaxEnd = state;
      assert(() {
        debugStateScans++;
        return true;
      }());
    }
  }

  /// Removes a deleted line's tokens without discarding unrelated cached lines.
  void evict(WorkspaceSyntaxLine line) => _tokens.remove(line);

  /// Generates tokens only when their paragraph is requested for rendering.
  List<WorkspaceSyntaxToken> tokens(WorkspaceSyntaxLine line) {
    if (_language == WorkspaceSyntaxLanguage.plainText) return const [];
    final cached = _tokens.remove(line);
    if (cached != null) {
      _tokens[line] = cached;
      return cached;
    }
    final result = _lexer.scan(line.content, line.syntaxStart!);
    assert(
      result.state == line.syntaxEnd,
      'State indexing and visible lexing must agree',
    );
    assert(() {
      debugTokenScans++;
      return true;
    }());
    _tokens[line] = result.tokens;
    return result.tokens;
  }

  /// Builds color-only spans, retaining every original UTF-16 code unit exactly.
  TextSpan span(
    WorkspaceSyntaxLine line,
    TextStyle? style,
    WorkspaceSyntaxPalette palette,
  ) {
    final intervals = tokens(line);
    if (intervals.isEmpty) return TextSpan(text: line.content, style: style);
    final children = <InlineSpan>[];
    var cursor = 0;
    for (final token in intervals) {
      if (cursor < token.start) {
        children.add(
          TextSpan(text: line.content.substring(cursor, token.start)),
        );
      }
      children.add(
        TextSpan(
          text: line.content.substring(token.start, token.end),
          style: palette.style(token.kind),
        ),
      );
      cursor = token.end;
    }
    if (cursor < line.content.length) {
      children.add(TextSpan(text: line.content.substring(cursor)));
    }
    return TextSpan(style: style, children: children);
  }

  /// Caps visible token storage independently from lightweight multiline states.
  void trimCache(Set<WorkspaceSyntaxLine> retained, int capacity) {
    final limit = math.max(capacity, retained.length);
    final victims = _tokens.keys
        .where((line) => !retained.contains(line))
        .take(math.max(0, _tokens.length - limit))
        .toList();
    for (final line in victims) {
      _tokens.remove(line);
    }
  }

  /// Releases all colored intervals when the owning document is disposed.
  void dispose() => _tokens.clear();
}
