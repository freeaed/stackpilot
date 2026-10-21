import 'dart:io';

import 'package:flutter/material.dart';

import 'app.dart';
import 'core/stack_layout.dart';

const _defaultRootCandidates = [r'C:\laragon-wamp', r'C:\laragon'];

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();

  final requestedRoot = _requestedRoot(args);
  final layout = requestedRoot != null
      ? StackLayout.detect(requestedRoot)
      : _detectInstalledStack();

  runApp(
    StackPilotApp(
      layout: layout,
      attemptedRoot: requestedRoot ?? _defaultRootCandidates.first,
    ),
  );
}

String? _requestedRoot(List<String> args) {
  for (final argument in args) {
    const prefix = '--stack-root=';
    if (argument.startsWith(prefix)) {
      final value = argument.substring(prefix.length).trim();
      if (value.isNotEmpty) {
        return value;
      }
    }
  }

  final fromEnvironment =
      Platform.environment['STACKPILOT_STACK_ROOT'] ??
      Platform.environment['LARASERVER_STACK_ROOT'];
  if (fromEnvironment != null && fromEnvironment.trim().isNotEmpty) {
    return fromEnvironment.trim();
  }

  return null;
}

StackLayout? _detectInstalledStack() {
  for (final candidate in _defaultRootCandidates) {
    final layout = StackLayout.detect(candidate);
    if (layout != null) {
      return layout;
    }
  }
  return null;
}
