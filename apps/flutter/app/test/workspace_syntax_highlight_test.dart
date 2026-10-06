import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operit2/ui/features/chat/components/workspace/file_preview/WorkspaceTextLayout.dart';
import 'package:operit2/ui/features/chat/components/workspace/file_preview/WorkspaceVirtualTextEditor.dart';
import 'package:operit2/ui/features/chat/components/workspace/file_preview/WorkspaceZoomScrollController.dart';
import 'package:operit2/ui/features/chat/components/workspace/file_preview/syntax/WorkspaceSyntaxLanguage.dart';
import 'package:operit2/ui/features/chat/components/workspace/file_preview/syntax/WorkspaceSyntaxLexer.dart';
import 'package:operit2/ui/features/chat/components/workspace/file_preview/syntax/WorkspaceSyntaxPalette.dart';
import 'package:operit2/ui/features/chat/components/workspace/file_preview/syntax/WorkspaceSyntaxToken.dart';

const _samples = <WorkspaceSyntaxLanguage, String>{
  WorkspaceSyntaxLanguage.dart: 'final String text = "中文 👩‍💻"; // comment',
  WorkspaceSyntaxLanguage.rust:
      'pub fn main() { let value: u32 = 42; } // comment',
  WorkspaceSyntaxLanguage.javascript: 'const value = `hello`; // comment',
  WorkspaceSyntaxLanguage.typescript:
      'interface Item { name: string; } // comment',
  WorkspaceSyntaxLanguage.python: 'def greet(): return "hello" # comment',
  WorkspaceSyntaxLanguage.java:
      'public class Main { int value = 42; } // comment',
  WorkspaceSyntaxLanguage.kotlin:
      'fun main() { val name = "hello" } // comment',
  WorkspaceSyntaxLanguage.swift:
      'func greet() { let value: Int = 42 } // comment',
  WorkspaceSyntaxLanguage.c: 'const int value = 42; /* comment */',
  WorkspaceSyntaxLanguage.cpp:
      'class Main { public: int value = 42; }; // comment',
  WorkspaceSyntaxLanguage.csharp:
      'public class Main { string value = "hello"; }',
  WorkspaceSyntaxLanguage.go: 'func main() { var value = 42 } // comment',
  WorkspaceSyntaxLanguage.php:
      r'<?php function greet() { return $value; } // comment',
  WorkspaceSyntaxLanguage.ruby: 'def greet; return "hello"; end # comment',
  WorkspaceSyntaxLanguage.lua: 'local value = "hello" -- comment',
  WorkspaceSyntaxLanguage.shell: r'if true; then echo "$HOME"; fi # comment',
  WorkspaceSyntaxLanguage.powershell:
      r'function Get-Value { return $value } # comment',
  WorkspaceSyntaxLanguage.sql:
      "SELECT id FROM users WHERE name = 'hello'; -- comment",
  WorkspaceSyntaxLanguage.json:
      '{"name": "hello", "enabled": true, "count": 42}',
  WorkspaceSyntaxLanguage.jsonc: '{"name": "hello", "count": 42} // comment',
  WorkspaceSyntaxLanguage.yaml: 'name: "hello" # comment',
  WorkspaceSyntaxLanguage.toml: 'name = "hello" # comment',
  WorkspaceSyntaxLanguage.ini: 'name = "hello" ; comment',
  WorkspaceSyntaxLanguage.html:
      '<div class="hello">world</div> <!-- comment -->',
  WorkspaceSyntaxLanguage.xml: '<item name="hello" /> <!-- comment -->',
  WorkspaceSyntaxLanguage.css:
      '.item { color: #ffffff; width: 12px; } /* comment */',
  WorkspaceSyntaxLanguage.scss:
      r'$size: 12px; .item { width: $size; } // comment',
  WorkspaceSyntaxLanguage.less:
      '@size: 12px; .item { width: @size; } // comment',
  WorkspaceSyntaxLanguage.markdown:
      '# Heading with `code` and [link](https://example.test)',
  WorkspaceSyntaxLanguage.dockerfile: 'FROM alpine:3.20 # comment',
  WorkspaceSyntaxLanguage.makefile: 'include config.mk # comment',
  WorkspaceSyntaxLanguage.cmake: 'project(example) # comment',
  WorkspaceSyntaxLanguage.diff: '+ inserted line',
};

/// Verifies language grammars, incremental states, color-only layout, and input.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'filename and extension registry selects explicit host-neutral languages',
    () {
      const paths = <String, WorkspaceSyntaxLanguage>{
        r'C:\src\main.DART': WorkspaceSyntaxLanguage.dart,
        '/a.py.dir/main.rs': WorkspaceSyntaxLanguage.rust,
        '/src/ui.tsx': WorkspaceSyntaxLanguage.typescript,
        '/src/ui.jsx': WorkspaceSyntaxLanguage.javascript,
        'Dockerfile': WorkspaceSyntaxLanguage.dockerfile,
        'Dockerfile.release': WorkspaceSyntaxLanguage.dockerfile,
        'Containerfile': WorkspaceSyntaxLanguage.dockerfile,
        'Makefile': WorkspaceSyntaxLanguage.makefile,
        'CMakeLists.txt': WorkspaceSyntaxLanguage.cmake,
        '.bashrc': WorkspaceSyntaxLanguage.shell,
        '.env.local': WorkspaceSyntaxLanguage.ini,
        'Gemfile': WorkspaceSyntaxLanguage.ruby,
        'app.yaml': WorkspaceSyntaxLanguage.yaml,
        'app.jsonc': WorkspaceSyntaxLanguage.jsonc,
        'image.svg': WorkspaceSyntaxLanguage.xml,
        'component.vue': WorkspaceSyntaxLanguage.html,
        'plain.txt': WorkspaceSyntaxLanguage.plainText,
        'config.py/README': WorkspaceSyntaxLanguage.plainText,
      };
      for (final entry in paths.entries) {
        expect(
          WorkspaceSyntaxLanguage.forPath(entry.key),
          entry.value,
          reason: entry.key,
        );
      }
      expect(_samples.length, WorkspaceSyntaxLanguage.values.length - 1);
    },
  );

  for (final entry in _samples.entries) {
    test(
      '${entry.key.name} produces ordered source-preserving lexical tokens',
      () {
        final lexer = WorkspaceSyntaxLexer(entry.key);
        final result = lexer.scan(entry.value, WorkspaceSyntaxState.empty);
        final indexed = lexer.scan(
          entry.value,
          WorkspaceSyntaxState.empty,
          tokens: false,
        );
        expect(indexed.state, result.state);
        expect(indexed.tokens, isEmpty);
        expect(result.tokens, isNotEmpty);
        _verifyIntervals(entry.value, result.tokens);
        final layout = WorkspaceTextLayout(entry.value, language: entry.key);
        addTearDown(layout.dispose);
        _configure(layout);
        expect(layout.paragraph(0).text!.toPlainText(), entry.value);
      },
    );
  }

  test('keywords and comments inside strings are never separately colored', () {
    final layout = WorkspaceTextLayout(
      'const value = "return /* not a comment */"; // return 42',
      language: WorkspaceSyntaxLanguage.javascript,
    );
    addTearDown(layout.dispose);
    expect(_kindAt(layout, 0, 'const'), WorkspaceSyntaxTokenKind.keyword);
    expect(_kindAt(layout, 0, 'return'), WorkspaceSyntaxTokenKind.string);
    expect(_kindAt(layout, 0, '/*'), WorkspaceSyntaxTokenKind.string);
    expect(_kindAt(layout, 0, '//'), WorkspaceSyntaxTokenKind.comment);
    expect(_kindAt(layout, 0, '42'), WorkspaceSyntaxTokenKind.comment);
  });

  test(
    'raw and doubled quotes obey their language-specific closing grammar',
    () {
      final samples = <WorkspaceSyntaxLanguage, String>{
        WorkspaceSyntaxLanguage.python: r'value = r"\""; return 42',
        WorkspaceSyntaxLanguage.dart: r'final value = r"\"; return 42;',
        WorkspaceSyntaxLanguage.csharp:
            r'var value = @"first ""quoted"" last"; return 42;',
        WorkspaceSyntaxLanguage.sql: "SELECT 'can''t'; SELECT 42;",
      };
      for (final entry in samples.entries) {
        final layout = WorkspaceTextLayout(entry.value, language: entry.key);
        addTearDown(layout.dispose);
        expect(_kindAt(layout, 0, '42'), WorkspaceSyntaxTokenKind.number);
        expect(layout.lines[0].syntaxEnd, WorkspaceSyntaxState.empty);
      }
    },
  );

  test('operators adjacent to region openers cannot swallow lexer state', () {
    final code = WorkspaceTextLayout(
      'let value = 1+/* first\nlast */2;',
      language: WorkspaceSyntaxLanguage.javascript,
    );
    addTearDown(code.dispose);
    expect(_kindAt(code, 0, 'first'), WorkspaceSyntaxTokenKind.comment);
    expect(_kindAt(code, 1, 'last'), WorkspaceSyntaxTokenKind.comment);
    expect(_kindAt(code, 1, '2'), WorkspaceSyntaxTokenKind.number);
    final yaml = WorkspaceTextLayout(
      'key:|\n  literal\nnext: 42',
      language: WorkspaceSyntaxLanguage.yaml,
    );
    addTearDown(yaml.dispose);
    expect(_kindAt(yaml, 1, 'literal'), WorkspaceSyntaxTokenKind.string);
    expect(_kindAt(yaml, 2, '42'), WorkspaceSyntaxTokenKind.number);
  });

  test('JSON keys, values, literals and Unicode source keep exact offsets', () {
    const text = '{"中文👩‍💻": "e\u0301", "flag": true, "count": 42}';
    final layout = WorkspaceTextLayout(
      text,
      language: WorkspaceSyntaxLanguage.json,
    );
    addTearDown(layout.dispose);
    expect(_kindAt(layout, 0, '中文'), WorkspaceSyntaxTokenKind.property);
    expect(_kindAt(layout, 0, 'e\u0301'), WorkspaceSyntaxTokenKind.string);
    expect(_kindAt(layout, 0, 'true'), WorkspaceSyntaxTokenKind.literal);
    expect(_kindAt(layout, 0, '42'), WorkspaceSyntaxTokenKind.number);
    _configure(layout);
    expect(layout.paragraph(0).text!.toPlainText(), text);
  });

  test(
    'Rust raw strings, lifetimes and nested comments retain multiline state',
    () {
      final layout = WorkspaceTextLayout(
        '/* outer\n/* inner */ still outer\n*/ let text = r##"first\n"# is not the end\nlast"##;\nfn borrow<\'a>(value: &\'a str) {}',
        language: WorkspaceSyntaxLanguage.rust,
      );
      addTearDown(layout.dispose);
      expect(
        _kindAt(layout, 1, 'still outer'),
        WorkspaceSyntaxTokenKind.comment,
      );
      expect(_kindAt(layout, 2, 'let'), WorkspaceSyntaxTokenKind.keyword);
      expect(_kindAt(layout, 3, 'not'), WorkspaceSyntaxTokenKind.string);
      expect(_kindAt(layout, 4, 'last'), WorkspaceSyntaxTokenKind.string);
      expect(_kindAt(layout, 5, 'fn'), WorkspaceSyntaxTokenKind.keyword);
      expect(_kindAt(layout, 5, "'a"), WorkspaceSyntaxTokenKind.meta);
      expect(layout.lines.last.syntaxEnd, WorkspaceSyntaxState.empty);
    },
  );

  test(
    'Python and TOML triple quoted strings cross logical line boundaries',
    () {
      for (final language in [
        WorkspaceSyntaxLanguage.python,
        WorkspaceSyntaxLanguage.toml,
      ]) {
        final layout = WorkspaceTextLayout(
          'name = """start\nreturn 42 # not a comment\nend"""\nvalue = 7',
          language: language,
        );
        addTearDown(layout.dispose);
        expect(_kindAt(layout, 1, 'return'), WorkspaceSyntaxTokenKind.string);
        expect(_kindAt(layout, 1, '#'), WorkspaceSyntaxTokenKind.string);
        expect(_kindAt(layout, 3, '7'), WorkspaceSyntaxTokenKind.number);
      }
    },
  );

  test('Lua brackets, C++ raw delimiters and SQL dollar quotes close exactly', () {
    final samples = <WorkspaceSyntaxLanguage, String>{
      WorkspaceSyntaxLanguage.lua:
          'local text = [=[first\nreturn ]] still string\nend]=]\nreturn 42',
      WorkspaceSyntaxLanguage.cpp:
          'auto text = R"tag(first\nreturn )" still string\nend)tag";\nreturn 42;',
      WorkspaceSyntaxLanguage.sql:
          'SELECT \$body\$first\nSELECT \$other\$ still string\nend\$body\$;\nSELECT 42;',
    };
    for (final entry in samples.entries) {
      final layout = WorkspaceTextLayout(entry.value, language: entry.key);
      addTearDown(layout.dispose);
      expect(_kindAt(layout, 1, 'still'), WorkspaceSyntaxTokenKind.string);
      expect(_kindAt(layout, 3, '42'), WorkspaceSyntaxTokenKind.number);
      expect(layout.lines.last.syntaxEnd, WorkspaceSyntaxState.empty);
    }
  });

  test('markup attributes span lines without coloring quotes in body text', () {
    final layout = WorkspaceTextLayout(
      '<node\n name="first\nlast">hello "world"</node>\n<!-- first\nlast -->',
      language: WorkspaceSyntaxLanguage.xml,
    );
    addTearDown(layout.dispose);
    expect(_kindAt(layout, 0, '<node'), WorkspaceSyntaxTokenKind.tag);
    expect(_kindAt(layout, 1, 'name'), WorkspaceSyntaxTokenKind.property);
    expect(_kindAt(layout, 2, 'last'), WorkspaceSyntaxTokenKind.string);
    expect(_kindAt(layout, 2, 'world'), isNull);
    expect(_kindAt(layout, 4, 'last'), WorkspaceSyntaxTokenKind.comment);
    expect(layout.lines.last.syntaxEnd, WorkspaceSyntaxState.empty);
  });

  test(
    'YAML block scalars stop at dedent and Markdown fences close by length',
    () {
      final yaml = WorkspaceTextLayout(
        'message: |\n  return true # literal\n\nnext: 42',
        language: WorkspaceSyntaxLanguage.yaml,
      );
      addTearDown(yaml.dispose);
      expect(_kindAt(yaml, 1, '#'), WorkspaceSyntaxTokenKind.string);
      expect(_kindAt(yaml, 3, 'next'), WorkspaceSyntaxTokenKind.property);
      expect(_kindAt(yaml, 3, '42'), WorkspaceSyntaxTokenKind.number);
      final markdown = WorkspaceTextLayout(
        '````dart\n# not a heading\n```\n````\n# Heading',
        language: WorkspaceSyntaxLanguage.markdown,
      );
      addTearDown(markdown.dispose);
      expect(_kindAt(markdown, 1, '#'), WorkspaceSyntaxTokenKind.string);
      expect(_kindAt(markdown, 2, '```'), WorkspaceSyntaxTokenKind.string);
      expect(_kindAt(markdown, 4, '#'), WorkspaceSyntaxTokenKind.heading);
      expect(markdown.lines.last.syntaxEnd, WorkspaceSyntaxState.empty);
    },
  );

  test(
    'local edits retain tokens and paragraphs after lexical state converges',
    () {
      final source = List.generate(2000, (i) => 'let value$i = $i;').join('\n');
      final layout = WorkspaceTextLayout(
        source,
        language: WorkspaceSyntaxLanguage.rust,
      );
      addTearDown(layout.dispose);
      _configure(layout);
      final last = layout.paragraph(1999);
      final lastTokens = layout.syntax.tokens(layout.lines.last);
      final before = layout.syntax.debugStateScans;
      layout.updateText(source.replaceFirst('value2 = 2', 'value2 = 3'));
      expect(layout.syntax.debugStateScans - before, lessThanOrEqualTo(3));
      expect(identical(layout.paragraph(1999), last), isTrue);
      expect(
        identical(layout.syntax.tokens(layout.lines.last), lastTokens),
        isTrue,
      );
      final comments = WorkspaceTextLayout(
        'let a = 1;\nlet b = 2;\n/* existing */\nlet c = 3;',
        language: WorkspaceSyntaxLanguage.rust,
      );
      addTearDown(comments.dispose);
      _configure(comments);
      final middle = comments.paragraph(1);
      final tail = comments.paragraph(3);
      comments.updateText(
        '/* let a = 1;\nlet b = 2;\n/* existing */\n*/ let c = 3;',
      );
      expect(_kindAt(comments, 1, 'let'), WorkspaceSyntaxTokenKind.comment);
      expect(identical(comments.paragraph(1), middle), isFalse);
      expect(_kindAt(comments, 3, 'let'), WorkspaceSyntaxTokenKind.keyword);
      expect(identical(comments.paragraph(3), tail), isFalse);
    },
  );

  test('color-only highlighting preserves wrapping and caret geometry', () {
    const source =
        'final String 中文 = "e\u0301 👩‍💻 text"; // comment ${42}\n${42}';
    final plain = WorkspaceTextLayout(source);
    final colored = WorkspaceTextLayout(
      source,
      language: WorkspaceSyntaxLanguage.dart,
    );
    addTearDown(plain.dispose);
    addTearDown(colored.dispose);
    for (final width in [80.0, 160.0, 320.0]) {
      _configure(plain, width: width);
      _configure(colored, width: width);
      for (var i = 0; i < plain.lines.length; i++) {
        final a = plain.paragraph(i);
        final b = colored.paragraph(i);
        expect(b.height, closeTo(a.height, 0.0001));
        for (
          var offset = 0;
          offset <= plain.lines[i].content.length;
          offset++
        ) {
          final pos = TextPosition(offset: offset);
          expect(
            b.getOffsetForCaret(pos, Rect.zero),
            a.getOffsetForCaret(pos, Rect.zero),
          );
        }
      }
    }
    final tokenScans = colored.syntax.debugTokenScans;
    colored.configureSyntax(
      WorkspaceSyntaxLanguage.dart,
      const WorkspaceSyntaxPalette(Brightness.dark),
    );
    expect(colored.paragraph(0).text!.toPlainText(), plain.lines[0].content);
    expect(colored.syntax.debugTokenScans, tokenScans);
    expect(colored.paragraph(0).height, plain.paragraph(0).height);
  });

  test('ten thousand source lines cache only requested colored paragraphs', () {
    final layout = WorkspaceTextLayout(
      List.generate(
        10000,
        (i) => 'let value$i = "中文 👩‍💻"; // comment',
      ).join('\n'),
      language: WorkspaceSyntaxLanguage.rust,
    );
    addTearDown(layout.dispose);
    _configure(layout);
    expect(layout.syntax.debugStateScans, 10000);
    expect(layout.syntax.debugTokenScans, 0);
    for (var page = 0; page < 150; page++) {
      final first = page * 60;
      final retained = <WorkspaceTextLine>{};
      for (var i = first; i < first + 40; i++) {
        layout.paragraph(i);
        retained.add(layout.lines[i]);
      }
      layout.trimCache(retained);
      expect(layout.syntax.cachedLines, lessThanOrEqualTo(128));
      expect(layout.cachedParagraphs, lessThanOrEqualTo(128));
    }
    final scans = layout.syntax.debugTokenScans;
    for (final width in [100.0, 200.0, 300.0]) {
      _configure(layout, width: width);
      layout.paragraph(8970);
    }
    expect(layout.syntax.debugTokenScans, scans);
  });

  for (final language in [
    WorkspaceSyntaxLanguage.rust,
    WorkspaceSyntaxLanguage.python,
    WorkspaceSyntaxLanguage.yaml,
    WorkspaceSyntaxLanguage.xml,
    WorkspaceSyntaxLanguage.javascript,
    WorkspaceSyntaxLanguage.shell,
  ]) {
    test(
      '${language.name} incremental states match full indexing during unfinished edits',
      () {
        var text =
            '${_samples[language]}\n/* first\nlast */\n"""first\nlast"""\n# comment';
        final layout = WorkspaceTextLayout(text, language: language);
        addTearDown(layout.dispose);
        final random = Random(194 + language.index);
        const insertions = [
          'a',
          '\n',
          '\r\n',
          '\r',
          '',
          '/*',
          '*/',
          '"',
          "'",
          'r#"',
          '\\',
          '#',
          '\${value}',
          '👩‍💻',
          '<node>',
          '```',
          '  key: |',
        ];
        for (var edit = 0; edit < 120; edit++) {
          final start = random.nextInt(text.length + 1);
          final end = start + random.nextInt(text.length - start + 1);
          text = text.replaceRange(
            start,
            end,
            insertions[random.nextInt(insertions.length)],
          );
          layout.updateText(text);
          final fresh = WorkspaceTextLayout(text, language: language);
          for (var i = 0; i < layout.lines.length; i++) {
            expect(
              layout.lines[i].syntaxStart,
              fresh.lines[i].syntaxStart,
              reason: 'edit=$edit line=$i source=$text',
            );
            expect(
              layout.lines[i].syntaxEnd,
              fresh.lines[i].syntaxEnd,
              reason: 'edit=$edit line=$i source=$text',
            );
            final lexer = WorkspaceSyntaxLexer(language);
            final indexed = lexer.scan(
              layout.lines[i].content,
              layout.lines[i].syntaxStart!,
              tokens: false,
            );
            final colored = lexer.scan(
              layout.lines[i].content,
              layout.lines[i].syntaxStart!,
            );
            expect(
              colored.state,
              indexed.state,
              reason: 'edit=$edit line=$i source=$text',
            );
            final tokens = layout.syntax.tokens(layout.lines[i]);
            _verifyIntervals(layout.lines[i].content, tokens);
            expect(
              tokens.map((t) => (t.start, t.end, t.kind)).toList(),
              fresh.syntax
                  .tokens(fresh.lines[i])
                  .map((t) => (t.start, t.end, t.kind))
                  .toList(),
            );
          }
          fresh.dispose();
        }
      },
    );
  }

  testWidgets(
    'colored ten-thousand-line editor keeps viewport-only work bounded',
    (tester) async {
      await tester.pumpWidget(
        _SyntaxEditor(
          text: List.generate(
            10000,
            (i) => 'let value$i = "中文 👩‍💻"; // comment',
          ).join('\n'),
          language: WorkspaceSyntaxLanguage.rust,
        ),
      );
      await tester.pumpAndSettle();
      final state = tester.state<WorkspaceVirtualTextEditorState>(
        find.byType(WorkspaceVirtualTextEditor),
      );
      final render = state.renderEditable;
      final syntax = render.textLayout.syntax;
      expect(syntax.debugStateScans, 10000);
      expect(syntax.debugTokenScans, lessThan(100));
      expect(render.debugParagraphLayouts, lessThan(100));
      expect(render.debugPaintedParagraphs, lessThan(50));
      final scans = syntax.debugTokenScans;
      for (var frame = 0; frame < 20; frame++) {
        render.markNeedsPaint();
        await tester.pump();
      }
      expect(syntax.debugTokenScans, scans);
      state.widget.scrollController.jumpTo(50000);
      await tester.pump();
      expect(syntax.debugTokenScans - scans, lessThan(100));
      final beforeSelection = syntax.debugTokenScans;
      state.widget.controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: state.widget.controller.text.length,
      );
      await tester.pump();
      expect(syntax.debugTokenScans, beforeSelection);
      expect(syntax.cachedLines, lessThanOrEqualTo(128));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'colored virtual editor retains native IME state and theme updates',
    (tester) async {
      const initial = 'final value = "中文";\n// comment';
      await tester.pumpWidget(const _SyntaxEditor(text: initial));
      await tester.pumpAndSettle();
      final state = tester.state<WorkspaceVirtualTextEditorState>(
        find.byType(WorkspaceVirtualTextEditor),
      );
      final layout = state.renderEditable.textLayout;
      expect(layout.syntax.language, WorkspaceSyntaxLanguage.dart);
      final painter = layout.paragraph(0);
      state.requestKeyboard();
      await tester.pump();
      const edited = 'final value = "中文👩‍💻";\n// comment';
      const value = TextEditingValue(
        text: edited,
        selection: TextSelection.collapsed(offset: 18),
        composing: TextRange(start: 15, end: 18),
      );
      tester.testTextInput.updateEditingValue(value);
      await tester.pump();
      expect(state.textEditingValue, value);
      expect(layout.paragraph(0).text!.toPlainText(), edited.split('\n')[0]);
      await tester.pumpWidget(
        const _SyntaxEditor(text: initial, brightness: Brightness.dark),
      );
      await tester.pump();
      expect(state.textEditingValue, value);
      expect(identical(layout.paragraph(0), painter), isFalse);
      await tester.pumpWidget(
        const _SyntaxEditor(
          text: initial,
          language: WorkspaceSyntaxLanguage.plainText,
          brightness: Brightness.dark,
        ),
      );
      await tester.pump();
      expect(layout.syntax.language, WorkspaceSyntaxLanguage.plainText);
      expect(state.textEditingValue, value);
      expect(tester.takeException(), isNull);
    },
  );
}

/// Configures deterministic paragraph metrics independently from token colors.
void _configure(WorkspaceTextLayout layout, {double width = 160}) =>
    layout.configure(
      width,
      const TextStyle(fontSize: 14, height: 1.45),
      TextScaler.noScaling,
      TextDirection.ltr,
    );

/// Ensures all lexical ranges remain ordered, nonempty UTF-16 source intervals.
void _verifyIntervals(String text, List<WorkspaceSyntaxToken> tokens) {
  var end = 0;
  for (final token in tokens) {
    expect(token.start, greaterThanOrEqualTo(end));
    expect(token.end, greaterThan(token.start));
    expect(token.end, lessThanOrEqualTo(text.length));
    end = token.end;
  }
}

/// Reads the lexical category covering an exact source substring in a line.
WorkspaceSyntaxTokenKind? _kindAt(
  WorkspaceTextLayout layout,
  int line,
  String text,
) {
  final source = layout.lines[line];
  final offset = source.content.indexOf(text);
  expect(offset, greaterThanOrEqualTo(0));
  for (final token in layout.syntax.tokens(source)) {
    if (token.start <= offset && token.end > offset) return token.kind;
  }
  return null;
}

/// Keeps document and history ownership stable while grammar and theme change.
class _SyntaxEditor extends StatefulWidget {
  /// Creates a common-platform editor harness without host-specific branches.
  const _SyntaxEditor({
    required this.text,
    this.language = WorkspaceSyntaxLanguage.dart,
    this.brightness = Brightness.light,
  });

  final String text;
  final WorkspaceSyntaxLanguage language;
  final Brightness brightness;

  /// Creates persistent native editing resources for the syntax regression test.
  @override
  State<_SyntaxEditor> createState() => _SyntaxEditorState();
}

class _SyntaxEditorState extends State<_SyntaxEditor> {
  late final TextEditingController controller;
  final focus = FocusNode();
  final history = UndoHistoryController();
  final scroll = WorkspaceZoomScrollController();

  /// Installs the full document once, independently from render configuration.
  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: widget.text);
  }

  /// Builds the same virtual editor used by workspace file tabs.
  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: ThemeData(brightness: widget.brightness),
    home: Scaffold(
      body: WorkspaceVirtualTextEditor(
        controller: controller,
        focusNode: focus,
        undoController: history,
        scrollController: scroll,
        groupId: this,
        style: const TextStyle(color: Colors.black, fontSize: 14, height: 1.45),
        language: widget.language,
        onChanged: _changed,
        scrollPhysics: null,
        active: true,
      ),
    ),
  );

  /// Accepts native edits without replacing the document controller.
  void _changed(String text) {}

  /// Releases all test resources after the native connection is detached.
  @override
  void dispose() {
    controller.dispose();
    focus.dispose();
    history.dispose();
    scroll.dispose();
    super.dispose();
  }
}
