@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;
import 'package:webview_all_web/webview_all_web.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:operit2/ui/features/packages/screens/ToolPkgComposeDslWebViewBridgeRuntime.dart';

/// Verifies real iframe document-start ordering and data retention across entries.
void main() {
  test(
    'the first inline script reads edited file data before saving',
    () async {
      var file = <String, Object?>{
        'chanzhi_todos_v1': [
          {'id': 'persisted', 'text': 'original'},
        ],
      };
      for (var entry = 0; entry < 2; entry++) {
        if (entry == 1) {
          file = {
            'chanzhi_todos_v1': [
              {'id': 'persisted', 'text': 'edited-file'},
            ],
          };
        }
        final params = WebWebViewControllerCreationParams();
        final controller = WebWebViewController(params);
        final frame = params.iFrame;
        final loaded = Completer<void>();
        final saved = Completer<void>();
        final methods = <String>[];
        frame.addEventListener(
          'load',
          ((web.Event _) => loaded.complete()).toJS,
          web.AddEventListenerOptions(once: true),
        );

        /// Emulates the file-owning host without using page-local storage.
        Future<void> handleHostMessage(JavaScriptMessage message) async {
          try {
            final request = jsonDecode(message.message) as Map<String, dynamic>;
            if (request['type'] != 'invoke') {
              throw StateError('Unexpected bridge request type');
            }
            final payload = request['payload'] as Map<String, dynamic>;
            final method = payload['methodName'] as String;
            methods.add(method);
            Object? result;
            switch (method) {
              case 'loadData':
                result = {'success': true, 'data': file};
              case 'saveData':
                final args =
                    jsonDecode(payload['args'] as String) as List<dynamic>;
                file = Map<String, Object?>.from(args.single as Map);
                result = {'success': true};
              default:
                throw StateError('Unexpected host method: $method');
            }
            final response = jsonEncode({
              'id': request['id'],
              'success': true,
              'data': result,
            });
            await controller.runJavaScript(
              'window.__operitComposeDslWebViewHostReceive($response)',
            );
            if (method == 'saveData') saved.complete();
          } catch (error, stack) {
            if (!saved.isCompleted) saved.completeError(error, stack);
          }
        }

        await controller.addJavaScriptChannel(
          JavaScriptChannelParams(
            name: composeDslWebViewBridgeChannelName,
            onMessageReceived: Zone.current.bindUnaryCallback((
              JavaScriptMessage message,
            ) {
              unawaited(handleHostMessage(message));
            }),
          ),
        );
        final handle = await controller.addUserScript(
          WebViewUserScript(
            source: buildComposeDslWebViewBridgeRuntimeScript(
              javascriptInterfaces: const {
                'ChanzhiHost': ['loadData', 'saveData'],
              },
            ),
            forMainFrameOnly: false,
          ),
        );
        await controller.loadHtmlString('''
        <!DOCTYPE html><html><head><script>
          window.bridgePresentAtStartup = typeof window.ChanzhiHost.loadData === 'function';
          window.startup = ChanzhiHost.loadData().then(function(result) {
            window.visibleTodos = result.data.chanzhi_todos_v1;
            return ChanzhiHost.saveData(result.data);
          });
        </script></head><body>Plugin</body></html>
      ''');
        web.document.body!.appendChild(frame);
        await loaded.future.timeout(const Duration(seconds: 10));
        await saved.future.timeout(const Duration(seconds: 10));
        expect(
          await controller.runJavaScriptReturningResult(
            'window.bridgePresentAtStartup',
          ),
          true,
        );
        expect(methods, ['loadData', 'saveData']);
        final todos = file['chanzhi_todos_v1'] as List<dynamic>;
        expect((todos.single as Map)['id'], 'persisted');
        expect(
          (todos.single as Map)['text'],
          entry == 0 ? 'original' : 'edited-file',
        );
        await controller.removeUserScript(handle);
        frame.remove();
      }
    },
  );

  test(
    'removing a script affects reload and leaves registered channels intact',
    () async {
      final params = WebWebViewControllerCreationParams();
      final controller = WebWebViewController(params);
      final frame = params.iFrame;
      await controller.addJavaScriptChannel(
        JavaScriptChannelParams(name: 'ProbeHost', onMessageReceived: (_) {}),
      );
      final handle = await controller.addUserScript(
        const WebViewUserScript(source: 'window.documentStartProbe = 42;'),
      );

      /// Waits for one native iframe navigation without installing late page scripts.
      Future<void> load(Future<void> Function() navigation) async {
        final ready = Completer<void>();
        frame.addEventListener(
          'load',
          ((web.Event _) => ready.complete()).toJS,
          web.AddEventListenerOptions(once: true),
        );
        await navigation();
        if (!frame.isConnected) web.document.body!.appendChild(frame);
        await ready.future.timeout(const Duration(seconds: 10));
      }

      await load(
        () => controller.loadHtmlString(
          '<script>window.startupProbe = window.documentStartProbe;</script>',
        ),
      );
      expect(
        await controller.runJavaScriptReturningResult('window.startupProbe'),
        42,
      );
      await controller.removeUserScript(handle);
      await load(controller.reload);
      expect(
        await controller.runJavaScriptReturningResult(
          'typeof window.startupProbe',
        ),
        'undefined',
      );
      expect(
        await controller.runJavaScriptReturningResult(
          'typeof window.ProbeHost.postMessage',
        ),
        'function',
      );
      frame.remove();
    },
  );
  test(
    'URL documents receive registered code before the first page script',
    () async {
      final factory = _DocumentRequestFactory();
      final params = WebWebViewControllerCreationParams(
        httpRequestFactory: factory,
      );
      final controller = WebWebViewController(params);
      final frame = params.iFrame;
      final loaded = Completer<void>();
      frame.addEventListener(
        'load',
        ((web.Event _) => loaded.complete()).toJS,
        web.AddEventListenerOptions(once: true),
      );
      final handle = await controller.addUserScript(
        const WebViewUserScript(source: 'window.docStartProbe = 42;'),
      );
      await controller.loadRequest(
        LoadRequestParams(uri: Uri.parse('https://chanzhi.test/home')),
      );
      web.document.body!.appendChild(frame);
      await loaded.future.timeout(const Duration(seconds: 10));
      expect(factory.requests, ['https://chanzhi.test/home']);
      expect(
        await controller.runJavaScriptReturningResult(
          'window.valueSeenByFirstPageScript',
        ),
        42,
      );
      expect(await controller.currentUrl(), 'https://chanzhi.test/home');
      expect(frame.contentDocument!.baseURI, 'https://chanzhi.test/home');
      await controller.removeUserScript(handle);
      frame.remove();
    },
  );
}

/// Supplies one controlled HTTP document to exercise the production URL loading path.
class _DocumentRequestFactory extends HttpRequestFactory {
  final requests = <String>[];

  /// Returns an HTML document whose first script observes document-start state.
  @override
  Future<Object> request(
    String url, {
    String method = 'GET',
    bool withCredentials = false,
    String? mimeType,
    Map<String, String>? requestHeaders,
    Uint8List? sendData,
  }) async {
    requests.add(url);
    return web.Response(
      '<html><head><script>window.valueSeenByFirstPageScript = window.docStartProbe;</script></head><body>URL document</body></html>'
          .toJS,
      web.ResponseInit(
        headers:
            {'content-type': 'text/html; charset=utf-8'}.jsify()
                as web.HeadersInit,
      ),
    );
  }
}
