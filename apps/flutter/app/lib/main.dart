import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:desktop_widgets/desktop_widgets.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'core/application/CoreApplicationService.dart';
import 'core/errors/UnhandledErrorReporter.dart';
import 'core/logging/ClientLogger.dart';
import 'core/notifications/NotificationActivationService.dart';
import 'core/runtime/RuntimeBootstrapManager.dart';
import 'ui/features/packages/screens/GitHubOAuthLoginCallback.dart';
import 'ui/main/OperitApp.dart';
import 'ui/window/DetachedChatWindowApp.dart';
import 'ui/window/DesktopWidgetWindowApp.dart';
import 'ui/window/OperitWindowArguments.dart';
import 'ui/window/OperitWindowPlatform.dart';

const String _appStartupLogTag = 'AppStartup';

/// Runs the application startup sequence with structured diagnostics.
void main(List<String> arguments) async {
  late Zone startupZone;
  var applicationStarted = false;
  await runZonedGuarded(
    () async {
      startupZone = Zone.current;
      final startupStopwatch = Stopwatch()..start();
      final bindingStopwatch = Stopwatch()..start();
      WidgetsFlutterBinding.ensureInitialized();
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      consumeGitHubOAuthWebCallbackAtStartup();
      final bindingElapsedMs = bindingStopwatch.elapsedMilliseconds;
      final loggerStopwatch = Stopwatch()..start();
      await ClientLogger.initialize();
      ClientLogger.i(
        'widgets binding initialized elapsedMs=$bindingElapsedMs',
        tag: _appStartupLogTag,
      );
      ClientLogger.i(
        'client logger initialized elapsedMs=${loggerStopwatch.elapsedMilliseconds}',
        tag: _appStartupLogTag,
      );
      final hooksStopwatch = Stopwatch()..start();
      _installClientLogHooks();
      ClientLogger.i(
        'client log hooks installed elapsedMs=${hooksStopwatch.elapsedMilliseconds}',
        tag: _appStartupLogTag,
      );
      final startsDetachedChatWindow = _startsDetachedChatWindow(arguments);
      if (startsDetachedChatWindow) {
        ClientLogger.i(
          'skip process-owned startup for detached chat window',
          tag: _appStartupLogTag,
        );
        await RuntimeBootstrapManager.instance.initializeForDetachedWindow();
        ClientLogger.i(
          'detached runtime bootstrap state loaded',
          tag: _appStartupLogTag,
        );
      } else {
        NotificationActivationService.instance.initialize(arguments);
        final runtimeStopwatch = Stopwatch()..start();
        await RuntimeBootstrapManager.instance.initialize();
        ClientLogger.i(
          'runtime bootstrap initialized elapsedMs=${runtimeStopwatch.elapsedMilliseconds}',
          tag: _appStartupLogTag,
        );
      }
      final glassStopwatch = Stopwatch()..start();
      await LiquidGlassWidgets.initialize();
      ClientLogger.i(
        'liquid glass initialized elapsedMs=${glassStopwatch.elapsedMilliseconds}',
        tag: _appStartupLogTag,
      );
      await DesktopWidgets.run(
        arguments: arguments,
        widgetBuilder: (launch) {
          applicationStarted = true;
          return DesktopWidgetWindowApp(launch: launch);
        },
        application: () async {
          final windowStopwatch = Stopwatch()..start();
          final windowArguments = await readOperitWindowArguments();
          ClientLogger.i(
            'window arguments read type=${windowArguments.runtimeType} elapsedMs=${windowStopwatch.elapsedMilliseconds}',
            tag: _appStartupLogTag,
          );
          switch (windowArguments) {
            case MainWindowArguments():
              final coreStopwatch = Stopwatch()..start();
              CoreApplicationService.instance.initialize();
              ClientLogger.i(
                'core application initialize dispatched elapsedMs=${coreStopwatch.elapsedMilliseconds}',
                tag: _appStartupLogTag,
              );
              _runMainWindow();
              applicationStarted = true;
            case final DetachedChatWindowArguments detachedArguments:
              _runDetachedChatWindow(detachedArguments);
              applicationStarted = true;
          }
        },
      );
      ClientLogger.i(
        'startup done elapsedMs=${startupStopwatch.elapsedMilliseconds}',
        tag: _appStartupLogTag,
      );
    },
    (error, stackTrace) {
      startupZone.runGuarded(() {
        if (ClientLogger.isInitialized) {
          ClientLogger.e(
            'Uncaught zone error',
            tag: _appStartupLogTag,
            error: error,
            stackTrace: stackTrace,
          );
        }
        UnhandledErrorReporter.report(
          source: 'Zone',
          error: error,
          stackTrace: stackTrace,
        );
        if (!applicationStarted) {
          runApp(const StartupErrorApplication());
        }
      });
    },
  );
}

/// Identifies a detached chat engine from the launch contract before startup services run.
bool _startsDetachedChatWindow(List<String> arguments) {
  if (arguments.length < 3 || arguments[0] != 'multi_window') {
    return false;
  }
  try {
    return OperitWindowArguments.parse(arguments[2])
        is DetachedChatWindowArguments;
  } catch (_) {
    return false;
  }
}

/// Starts the main application window without touching runtime services.
void _runMainWindow() {
  ClientLogger.i('run main window', tag: _appStartupLogTag);
  runApp(
    LiquidGlassWidgets.wrap(
      respectSystemAccessibility: false,
      theme: GlassThemeData.simple(
        blur: 2.5,
        thickness: 36,
        quality: GlassQuality.standard,
      ),
      child: const OperitApp(),
    ),
  );
}

/// Starts a detached chat window after runtime configuration is loaded.
void _runDetachedChatWindow(DetachedChatWindowArguments arguments) {
  ClientLogger.i('run detached chat window', tag: _appStartupLogTag);
  runApp(
    LiquidGlassWidgets.wrap(
      respectSystemAccessibility: false,
      theme: GlassThemeData.simple(
        blur: 2.5,
        thickness: 36,
        quality: GlassQuality.standard,
      ),
      child: DetachedChatWindowApp(arguments: arguments),
    ),
  );
}

/// Routes Flutter framework diagnostics through the client logger.
void _installClientLogHooks() {
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null && message.isNotEmpty) {
      ClientLogger.v(
        message,
        verboseLevel: VerboseLevel.level6,
        tag: 'FlutterDebugPrint',
      );
    }
  };

  FlutterError.onError = (FlutterErrorDetails details) {
    ClientLogger.e(
      details.exceptionAsString(),
      tag: 'FlutterFramework',
      error: details.exception,
      stackTrace: details.stack,
    );
    FlutterError.presentError(details);
  };

  PlatformDispatcher.instance.onError = (error, stackTrace) {
    ClientLogger.e(
      'Uncaught platform error',
      tag: 'PlatformDispatcher',
      error: error,
      stackTrace: stackTrace,
    );
    UnhandledErrorReporter.report(
      source: 'Platform dispatcher',
      error: error,
      stackTrace: stackTrace,
    );
    return true;
  };
}
