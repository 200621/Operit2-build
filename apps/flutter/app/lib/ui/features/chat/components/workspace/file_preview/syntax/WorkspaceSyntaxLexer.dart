// ignore_for_file: file_names

import 'WorkspaceSyntaxLanguage.dart';
import 'WorkspaceSyntaxToken.dart';

/// Describes an immutable multiline comment, string, fence, or indented scalar.
class WorkspaceSyntaxRegion {
  /// Records the actual closing delimiter, including raw-string delimiter tags.
  WorkspaceSyntaxRegion({
    required this.start,
    required this.end,
    required this.kind,
    this.multiline = true,
    this.escape = false,
    this.escapeCharacter = '\\',
    this.doubledEnd = false,
    this.nested = false,
    this.closeLinePattern = '',
    this.indent,
  });

  final String start;
  final String end;
  final WorkspaceSyntaxTokenKind kind;
  final bool multiline;
  final bool escape;
  final String escapeCharacter;
  final bool doubledEnd;
  final bool nested;
  final String closeLinePattern;
  final int? indent;
  late final RegExp closeLine = RegExp(closeLinePattern);

  /// Compares lexical state by value so edit propagation stops at convergence.
  @override
  bool operator ==(Object other) =>
      other is WorkspaceSyntaxRegion &&
      other.start == start &&
      other.end == end &&
      other.kind == kind &&
      other.multiline == multiline &&
      other.escape == escape &&
      other.escapeCharacter == escapeCharacter &&
      other.doubledEnd == doubledEnd &&
      other.nested == nested &&
      other.closeLinePattern == closeLinePattern &&
      other.indent == indent;

  /// Hashes all grammar properties contributing to a line's outgoing state.
  @override
  int get hashCode => Object.hash(
    start,
    end,
    kind,
    multiline,
    escape,
    escapeCharacter,
    doubledEnd,
    nested,
    closeLinePattern,
    indent,
  );
}

/// Keeps only lightweight incoming and outgoing lexical context for each line.
class WorkspaceSyntaxState {
  /// Represents a lexical boundary without storing any colored text or spans.
  const WorkspaceSyntaxState({this.region, this.depth = 0, this.inTag = false});

  static const empty = WorkspaceSyntaxState();
  final WorkspaceSyntaxRegion? region;
  final int depth;
  final bool inTag;

  /// Enters or exits a region while retaining an enclosing markup tag context.
  WorkspaceSyntaxState withRegion(
    WorkspaceSyntaxRegion? next, [
    int nesting = 1,
  ]) {
    if (next == null && !inTag) return empty;
    return WorkspaceSyntaxState(
      region: next,
      depth: next == null ? 0 : nesting,
      inTag: inTag,
    );
  }

  /// Compares lexical context independently from paragraph geometry and colors.
  @override
  bool operator ==(Object other) =>
      other is WorkspaceSyntaxState &&
      other.region == region &&
      other.depth == depth &&
      other.inTag == inTag;

  /// Hashes the minimal cross-line lexer state.
  @override
  int get hashCode => Object.hash(region, depth, inTag);
}

/// Returns lexical context plus optional viewport-only token intervals.
class WorkspaceSyntaxResult {
  /// Shares the same lexer for state indexing and visible token generation.
  const WorkspaceSyntaxResult(this.state, this.tokens);

  final WorkspaceSyntaxState state;
  final List<WorkspaceSyntaxToken> tokens;
}

/// Tokenizes logical lines without ever copying or changing their source text.
class WorkspaceSyntaxLexer {
  /// Compiles one language's rules once, shared across all editor documents.
  WorkspaceSyntaxLexer(this.language)
    : definition = workspaceSyntaxDefinition(language);

  final WorkspaceSyntaxLanguage language;
  final WorkspaceSyntaxDefinition definition;
  late final _statePattern = _pattern(false, false);
  late final _tokenPattern = _pattern(true, false);
  late final _tagStatePattern = _pattern(false, true);
  late final _tagTokenPattern = _pattern(true, true);
  static final _colon = RegExp(r'\s*:');
  static final _assignment = RegExp(r'\s*=');
  static final _call = RegExp(r'\s*\(');
  static final _indent = RegExp(r'^[ \t]*');
  static final _fence = RegExp(r'[`~]+');
  static const _numbers =
      r'\b(?:0[xX][\da-fA-F_]+|0[bB][01_]+|\d[\d_]*(?:\.[\d_]*)?(?:[eE][+-]?[\d_]+)?(?:[A-Za-z][\w]*)?)\b';
  static const _groups = <String, WorkspaceSyntaxTokenKind>{
    'number': WorkspaceSyntaxTokenKind.number,
    'specialNumber': WorkspaceSyntaxTokenKind.number,
    'character': WorkspaceSyntaxTokenKind.string,
    'variable': WorkspaceSyntaxTokenKind.variable,
    'specialVariable': WorkspaceSyntaxTokenKind.variable,
    'meta': WorkspaceSyntaxTokenKind.meta,
    'property': WorkspaceSyntaxTokenKind.property,
    'tag': WorkspaceSyntaxTokenKind.tag,
    'heading': WorkspaceSyntaxTokenKind.heading,
    'link': WorkspaceSyntaxTokenKind.link,
    'operator': WorkspaceSyntaxTokenKind.operator,
    'punctuation': WorkspaceSyntaxTokenKind.punctuation,
    'tagEnd': WorkspaceSyntaxTokenKind.punctuation,
  };

  /// Builds state-only rules without allocating offscreen word or number tokens.
  ({RegExp expression, Set<String> groups}) _pattern(bool tokens, bool inTag) {
    final markup = definition.family == WorkspaceSyntaxFamily.markup;
    final parts = <String>[
      for (var i = 0; i < definition.delimiters.length; i++)
        if (!markup || inTag || !definition.delimiters[i].insideTagOnly)
          '(?<region$i>${definition.delimiters[i].pattern})',
      if (definition.lineComment.isNotEmpty)
        '(?<comment>${definition.lineComment})',
      if (markup) r'(?<tag></?[A-Za-z][\w:.-]*)|(?<meta><[!?][^>]*>)',
      if (markup && inTag) r'(?<tagEnd>/?>)',
      if (!markup && definition.extraPattern.isNotEmpty)
        definition.extraPattern,
      if (definition.variables)
        r'(?<variable>\$(?:\{[^}]*\}|\([^)]*\)|[\w:]+|[?@#*!\d]))',
      if (tokens &&
          (!markup || inTag) &&
          definition.family != WorkspaceSyntaxFamily.markdown) ...[
        '(?<number>$_numbers)',
        definition.family == WorkspaceSyntaxFamily.stylesheet ||
                definition.assignmentProperties
            ? r'(?<identifier>[$A-Za-z_][$\w-]*)'
            : r'(?<identifier>[$A-Za-z_][$\w]*)',
        r'(?<operator>[+*/%=!&|^~?:<>-])',
        r'(?<punctuation>[{}\[\](),;.])',
      ],
    ];
    final source = parts.join('|');
    return (
      expression: RegExp(
        source,
        caseSensitive: definition.caseSensitive,
        unicode: true,
      ),
      groups: RegExp(
        r'\(\?<([A-Za-z]\w*)>',
      ).allMatches(source).map((m) => m[1]!).toSet(),
    );
  }

  /// Scans one line; offscreen passes retain states but allocate no token lists.
  WorkspaceSyntaxResult scan(
    String text,
    WorkspaceSyntaxState incoming, {
    bool tokens = true,
  }) {
    if (definition.family == WorkspaceSyntaxFamily.plain) {
      return const WorkspaceSyntaxResult(WorkspaceSyntaxState.empty, []);
    }
    if (definition.family == WorkspaceSyntaxFamily.diff) {
      final output = tokens ? <WorkspaceSyntaxToken>[] : null;
      if (tokens && text.isNotEmpty) {
        final kind = switch (text.codeUnitAt(0)) {
          43 => WorkspaceSyntaxTokenKind.inserted,
          45 => WorkspaceSyntaxTokenKind.deleted,
          64 => WorkspaceSyntaxTokenKind.meta,
          _ => null,
        };
        if (kind != null) _emit(output, 0, text.length, kind);
      }
      return WorkspaceSyntaxResult(
        WorkspaceSyntaxState.empty,
        output ?? const [],
      );
    }
    final output = tokens ? <WorkspaceSyntaxToken>[] : null;
    var state = incoming;
    var cursor = 0;
    Iterator<RegExpMatch>? matches;
    // Empty lines still participate in region state, notably YAML block scalars.
    while (cursor < text.length || (cursor == 0 && state.region != null)) {
      final active = state.region;
      if (active != null) {
        final end = _consume(text, cursor, state);
        _emit(
          output,
          cursor,
          end.cursor,
          _stringKind(text, end.cursor, active.kind, end.closed),
        );
        state = end.state;
        cursor = end.cursor;
        matches = null;
        if (!end.closed || cursor >= text.length) break;
        continue;
      }
      final pattern = state.inTag
          ? (tokens ? _tagTokenPattern : _tagStatePattern)
          : (tokens ? _tokenPattern : _statePattern);
      matches ??= pattern.expression.allMatches(text, cursor).iterator;
      if (!matches.moveNext()) break;
      final match = matches.current;
      cursor = match.end;
      if (pattern.groups.contains('comment') &&
          match.namedGroup('comment') != null) {
        _emit(
          output,
          match.start,
          text.length,
          WorkspaceSyntaxTokenKind.comment,
        );
        break;
      }
      WorkspaceSyntaxDelimiter? delimiter;
      for (var i = 0; i < definition.delimiters.length; i++) {
        if (pattern.groups.contains('region$i') &&
            match.namedGroup('region$i') != null) {
          delimiter = definition.delimiters[i];
          break;
        }
      }
      if (delimiter != null) {
        final region = _region(delimiter, match[0]!);
        final end = _consume(text, cursor, state.withRegion(region));
        _emit(
          output,
          match.start,
          end.cursor,
          _stringKind(text, end.cursor, region.kind, end.closed),
        );
        state = end.state;
        cursor = end.cursor;
        matches = null;
        if (!end.closed) break;
        continue;
      }
      if (pattern.groups.contains('yamlBlock') &&
          match.namedGroup('yamlBlock') != null) {
        final region = WorkspaceSyntaxRegion(
          start: match[0]!,
          end: '',
          kind: WorkspaceSyntaxTokenKind.string,
          indent: _indent.firstMatch(text)!.end,
        );
        state = state.withRegion(region);
        _emit(
          output,
          match.start,
          text.length,
          WorkspaceSyntaxTokenKind.string,
        );
        break;
      }
      if (definition.family == WorkspaceSyntaxFamily.markup) {
        if (match.namedGroup('tag') != null) {
          state = const WorkspaceSyntaxState(inTag: true);
          matches = null;
        } else if (state.inTag && match.namedGroup('tagEnd') != null) {
          state = WorkspaceSyntaxState.empty;
          matches = null;
        }
      }
      if (tokens) {
        WorkspaceSyntaxTokenKind? kind;
        for (final entry in _groups.entries) {
          if (pattern.groups.contains(entry.key) &&
              match.namedGroup(entry.key) != null) {
            kind = entry.value;
            break;
          }
        }
        if (pattern.groups.contains('identifier') &&
            match.namedGroup('identifier') != null) {
          kind = _identifier(text, match, state.inTag);
        }
        if (kind != null) _emit(output, match.start, match.end, kind);
      }
    }
    return WorkspaceSyntaxResult(state, output ?? const []);
  }

  /// Resolves dynamic raw delimiters using the language's declared opener syntax.
  WorkspaceSyntaxRegion _region(
    WorkspaceSyntaxDelimiter delimiter,
    String opener,
  ) {
    var end = delimiter.end;
    var escape = delimiter.escape;
    var closeLinePattern = '';
    switch (delimiter.dynamicEnd) {
      case 'rust':
        end =
            '"${opener.substring(opener.indexOf('r') + 1, opener.length - 1)}';
      case 'lua':
        end =
            ']${opener.substring(opener.indexOf('[') + 1, opener.length - 1)}]';
      case 'cpp':
        end =
            ')${opener.substring(opener.indexOf('"') + 1, opener.length - 1)}"';
      case 'dart':
        escape = !opener.startsWith('r');
      case 'python':
        // Raw Python literals still escape their closing quote with backslashes.
        escape = true;
      case 'sql':
      case 'inline':
        end = opener;
      case 'markdown':
        end = _fence.firstMatch(opener)![0]!;
        closeLinePattern =
            '^ {0,3}${RegExp.escape(end[0])}{${end.length},}[ \\t]*\$';
    }
    return WorkspaceSyntaxRegion(
      start: opener,
      end: end,
      kind: delimiter.kind,
      multiline: delimiter.multiline,
      escape: escape,
      escapeCharacter: delimiter.escapeCharacter,
      doubledEnd: delimiter.doubledEnd,
      nested: delimiter.nested,
      closeLinePattern: closeLinePattern,
    );
  }

  /// Finds the exact region end without tokenizing its comment or string body.
  ({int cursor, WorkspaceSyntaxState state, bool closed}) _consume(
    String text,
    int cursor,
    WorkspaceSyntaxState state,
  ) {
    final region = state.region!;
    if (region.indent != null) {
      if (text.trim().isNotEmpty &&
          _indent.firstMatch(text)!.end <= region.indent!) {
        return (cursor: cursor, state: state.withRegion(null), closed: true);
      }
      return (cursor: text.length, state: state, closed: false);
    }
    if (region.closeLinePattern.isNotEmpty) {
      final closed = cursor == 0 && region.closeLine.hasMatch(text);
      return (
        cursor: text.length,
        state: closed ? state.withRegion(null) : state,
        closed: closed,
      );
    }
    var depth = state.depth;
    var search = cursor;
    while (search < text.length) {
      final close = text.indexOf(region.end, search);
      final open = region.nested ? text.indexOf(region.start, search) : -1;
      if (open >= 0 && (close < 0 || open < close)) {
        depth++;
        search = open + region.start.length;
        continue;
      }
      if (close < 0) break;
      var escapes = 0;
      if (region.escape) {
        for (
          var i = close - 1;
          i >= 0 && text.codeUnitAt(i) == region.escapeCharacter.codeUnitAt(0);
          i--
        ) {
          escapes++;
        }
      }
      search = close + region.end.length;
      if (escapes.isOdd) continue;
      if (region.doubledEnd && text.startsWith(region.end, search)) {
        search += region.end.length;
        continue;
      }
      depth--;
      if (depth == 0) {
        return (cursor: search, state: state.withRegion(null), closed: true);
      }
    }
    return (
      cursor: text.length,
      state: region.multiline
          ? state.withRegion(region, depth)
          : state.withRegion(null),
      closed: false,
    );
  }

  /// Distinguishes quoted mapping keys using their grammatical colon suffix.
  WorkspaceSyntaxTokenKind _stringKind(
    String text,
    int end,
    WorkspaceSyntaxTokenKind kind,
    bool closed,
  ) {
    if (kind == WorkspaceSyntaxTokenKind.string &&
        closed &&
        definition.family == WorkspaceSyntaxFamily.data &&
        _colon.matchAsPrefix(text, end) != null) {
      return WorkspaceSyntaxTokenKind.property;
    }
    return kind;
  }

  /// Classifies exact words, mapping keys, tag attributes, and callable names.
  WorkspaceSyntaxTokenKind? _identifier(
    String text,
    RegExpMatch match,
    bool inTag,
  ) {
    if (inTag) return WorkspaceSyntaxTokenKind.property;
    final raw = match[0]!;
    final word = definition.caseSensitive ? raw : raw.toLowerCase();
    if (definition.keywords.contains(word)) {
      return WorkspaceSyntaxTokenKind.keyword;
    }
    if (definition.types.contains(word)) return WorkspaceSyntaxTokenKind.type;
    if (definition.literals.contains(word)) {
      return WorkspaceSyntaxTokenKind.literal;
    }
    if (_colon.matchAsPrefix(text, match.end) != null ||
        (definition.assignmentProperties &&
            _assignment.matchAsPrefix(text, match.end) != null)) {
      return WorkspaceSyntaxTokenKind.property;
    }
    if (_call.matchAsPrefix(text, match.end) != null) {
      return WorkspaceSyntaxTokenKind.function;
    }
    return null;
  }

  /// Coalesces adjacent equal categories only when visible tokens are requested.
  static void _emit(
    List<WorkspaceSyntaxToken>? output,
    int start,
    int end,
    WorkspaceSyntaxTokenKind kind,
  ) {
    if (output == null || start == end) return;
    if (output.isNotEmpty &&
        output.last.end == start &&
        output.last.kind == kind) {
      output[output.length - 1] = WorkspaceSyntaxToken(
        output.last.start,
        end,
        kind,
      );
    } else {
      output.add(WorkspaceSyntaxToken(start, end, kind));
    }
  }
}
