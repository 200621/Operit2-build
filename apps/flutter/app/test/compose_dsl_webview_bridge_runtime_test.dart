import 'package:flutter_test/flutter_test.dart';
import 'package:operit2/ui/features/packages/screens/ToolPkgComposeDslWebViewBridgeRuntime.dart';

const _interfaces = <String, List<String>>{
  'ChanzhiHost': ['loadData', 'saveData'],
};

/// Verifies document-start injection without platform-specific application code.
void main() {
  test('explicit HTML embedding preserves the Kotlin markup contract', () {
    const html =
        '<!DOCTYPE html><HTML><HEAD lang="en">'
        '<script>ChanzhiHost.loadData()</script></HEAD>'
        '<body><script>startBridge()</script></body></HTML>';
    final prepared = injectComposeDslWebViewBridgeRuntimeIntoHtml(
      html,
      javascriptInterfaces: _interfaces,
    );
    expect(
      prepared.indexOf('data-operit-webview-bridge-runtime'),
      greaterThan(prepared.indexOf('<script>ChanzhiHost.loadData()')),
    );
    expect(
      prepared,
      contains(
        'var initialInterfaces = {"ChanzhiHost":["loadData","saveData"]}',
      ),
    );
    expect(
      prepared.indexOf('data-operit-webview-bridge-runtime'),
      lessThan(prepared.indexOf('<script>startBridge()')),
    );
    expect(prepared, isNot(contains('hiddenBridge.listInterfaces().then')));
    expect(
      prepared,
      endsWith('<body><script>startBridge()</script></body></HTML>'),
    );
  });

  test('HTML fragments and documents without a head are prepared once', () {
    for (final html in [
      '<html><body><script>startBridge()</script></body></html>',
      '<script>startBridge()</script>',
    ]) {
      final prepared = injectComposeDslWebViewBridgeRuntimeIntoHtml(
        html,
        javascriptInterfaces: _interfaces,
      );
      expect(
        prepared.indexOf('data-operit-webview-bridge-runtime'),
        lessThan(prepared.indexOf('<script>startBridge()')),
      );
      expect(
        injectComposeDslWebViewBridgeRuntimeIntoHtml(
          prepared,
          javascriptInterfaces: _interfaces,
        ),
        prepared,
      );
    }
  });

  test('descriptor names cannot terminate the injected script element', () {
    final script = buildComposeDslWebViewBridgeRuntimeScriptTag(
      javascriptInterfaces: const {
        '</script><script>bad()': ['</script>'],
      },
    );
    expect('</script>'.allMatches(script).length, 1);
    expect(script, contains(r'\u003c/script>'));
  });
}
