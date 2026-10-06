import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_all/webview_all.dart';
import 'package:webview_all_linux/webview_all_linux.dart';
import 'package:operit2/ui/features/packages/screens/ToolPkgComposeDslWebViewBridgeRuntime.dart';

/// Verifies that the shared facade uses Linux's existing native WebKit script API.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Linux document-start registration and removal retain the native handle',
    () async {
      const prefix = 'com.abandoft.webview_all_linux';
      const root = MethodChannel(prefix);
      const instance = MethodChannel('$prefix/27');
      const events = MethodChannel('$prefix/27/events');
      final nativeCalls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(root, (call) async {
        expect(call.method, 'createWebView');
        return 27;
      });
      messenger.setMockMethodCallHandler(instance, (call) async {
        nativeCalls.add(call);
        return null;
      });
      messenger.setMockMethodCallHandler(events, (call) async => null);
      addTearDown(() {
        messenger.setMockMethodCallHandler(root, null);
        messenger.setMockMethodCallHandler(instance, null);
        messenger.setMockMethodCallHandler(events, null);
      });
      final platform = LinuxWebViewController(
        const LinuxWebViewControllerCreationParams(),
      );
      final controller = WebViewController.fromPlatform(platform);
      final source = buildComposeDslWebViewBridgeRuntimeScript(
        javascriptInterfaces: const {
          'ChanzhiHost': ['loadData', 'saveData'],
        },
      );
      final handle = await controller.addDocumentStartJavaScript(source);
      final registration = nativeCalls.singleWhere(
        (call) => call.method == 'addUserScript',
      );
      final arguments = registration.arguments as Map<Object?, Object?>;
      expect(arguments['identifier'], handle);
      expect(
        arguments['source'],
        contains(
          'var initialInterfaces = {"ChanzhiHost":["loadData","saveData"]}',
        ),
      );
      expect(arguments['mainFrameOnly'], false);
      await controller.removeDocumentStartJavaScript(handle);
      final removal = nativeCalls.singleWhere(
        (call) => call.method == 'removeUserScript',
      );
      expect(removal.arguments, {'identifier': handle});
      await platform.dispose();
    },
  );
}
