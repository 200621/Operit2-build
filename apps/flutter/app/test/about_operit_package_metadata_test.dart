import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operit2/data/preferences/UserPreferencesManager.dart';
import 'package:operit2/ui/features/settings/about/AboutOperitScreen.dart';
import 'package:operit2/ui/theme/OperitTheme.dart';

/// Verifies the actual package metadata channel in an isolated plugin cache.
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'about page reports read errors and uses exact package metadata',
    (tester) async {
      const channel = MethodChannel('dev.fluttercommunity.plus/package_info');
      var requests = 0;
      var metadata = Completer<Map<String, Object>>();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) {
        expect(call.method, 'getAll');
        requests += 1;
        return metadata.future;
      });
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );

      await _pumpAbout(tester);
      expect(find.text('正在读取版本信息…'), findsOneWidget);
      expect(find.text('版本 2.0.0+6'), findsNothing);
      expect(requests, 1);

      final readError = PlatformException(
        code: 'PACKAGE_INFO_ERROR',
        message: 'Package metadata unavailable',
      );
      metadata.completeError(readError);
      await tester.pumpAndSettle();
      expect(find.text('版本信息读取失败：$readError'), findsOneWidget);
      expect(find.text('版本 2.0.0+6'), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      metadata = Completer<Map<String, Object>>();
      await _pumpAbout(tester);
      expect(find.text('正在读取版本信息…'), findsOneWidget);
      expect(requests, 2);

      metadata.complete(<String, Object>{
        'appName': 'Operit2',
        'packageName': 'app.operit',
        'version': '3.2.1',
        'buildNumber': '4321',
        'buildSignature': '',
      });
      await tester.pumpAndSettle();
      expect(find.text('版本 3.2.1+4321'), findsOneWidget);
      expect(find.text('正在读取版本信息…'), findsNothing);

      await _pumpAbout(tester, dark: true);
      await tester.pumpAndSettle();
      expect(find.text('版本 3.2.1+4321'), findsOneWidget);
      expect(requests, 2);
      expect(tester.takeException(), isNull);
    },
  );
}

/// Renders the About page with an optional theme for dependency rebuild checks.
Future<void> _pumpAbout(WidgetTester tester, {bool dark = false}) {
  return tester.pumpWidget(
    OperitTheme(
      initialThemePreferenceSnapshot:
          UserPreferencesManager.defaultThemePreferenceSnapshot,
      initialThemeIsReady: false,
      unconfiguredChildEnabled: true,
      hostInteractionHostsEnabled: false,
      child: Theme(
        data: dark ? ThemeData.dark() : ThemeData.light(),
        child: const Scaffold(body: AboutOperitScreen()),
      ),
    ),
  );
}
