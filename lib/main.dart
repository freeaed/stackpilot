import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app.dart';
import 'core/app_info.dart';
import 'core/app_log.dart';
import 'core/app_preferences.dart';
import 'core/stack_resolution.dart';
import 'core/window_shell.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  AppLog.initialize();
  AppLog.info(
    'Starting ${AppInfo.name} ${AppInfo.versionLabel} '
    '(${AppInfo.channel.id}) on ${Platform.operatingSystem} '
    '${Platform.operatingSystemVersion}',
  );

  FlutterError.onError = (details) {
    AppLog.error(
      'Flutter error: ${details.exceptionAsString()}',
      error: details.exception,
      stackTrace: details.stack,
    );
    FlutterError.presentError(details);
  };
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    AppLog.error('Unhandled platform error', error: error, stackTrace: stack);
    return false;
  };

  runZonedGuarded(
    () => _run(args),
    (error, stack) => AppLog.error(
      'Unhandled error',
      error: error,
      stackTrace: stack,
    ),
  );
}

Future<void> _run(List<String> args) async {
  final preferencesStore = AppPreferencesStore();
  final preferences = preferencesStore.load();
  final startup = resolveStartupStack(
    requestedRoot: _requestedRoot(args),
    preferences: preferences,
  );

  final layout = startup.layout;
  AppLog.info(
    layout == null
        ? 'No stack found (attempted ${startup.attemptedRoot})'
        : 'Using stack ${layout.root} (${layout.flavor.label})',
  );
  if (layout != null && layout.root != preferences.activeStack) {
    unawaited(
      preferencesStore.save(preferences.copyWith(activeStack: layout.root)),
    );
  }

  final windowShell = WindowShell(minimizeToTray: preferences.minimizeToTray);
  try {
    await windowShell.start();
  } on Object catch (error, stackTrace) {
    AppLog.warn(
      'Window and tray integration unavailable',
      error: error,
      stackTrace: stackTrace,
    );
    debugPrint('StackPilot: window and tray integration unavailable: $error');
  }

  runApp(
    StackPilotApp(
      layout: layout,
      attemptedRoot: startup.attemptedRoot,
      preferences: preferences,
      preferencesStore: preferencesStore,
    ),
  );
}

String? _requestedRoot(List<String> args) {
  for (final argument in args) {
    final prefix = '--stack-root=';
    if (argument.startsWith(prefix)) {
      final value = argument.substring(prefix.length).trim();
      if (value.isNotEmpty) {
        return value;
      }
    }
  }

  final environment = Platform.environment;
  final fromEnvironment =
      environment['STACKPILOT_STACK_ROOT'] ??
      environment['LARASERVER_STACK_ROOT'];
  if (fromEnvironment != null && fromEnvironment.trim().isNotEmpty) {
    return fromEnvironment.trim();
  }

  return null;
}
