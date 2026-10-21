import 'package:flutter/material.dart';

import 'core/service_manager.dart';
import 'core/stack_layout.dart';
import 'ui/dashboard.dart';

class StackPilotApp extends StatelessWidget {
  const StackPilotApp({
    super.key,
    required this.layout,
    required this.attemptedRoot,
    this.serviceManagerFactory,
  });

  final StackLayout? layout;
  final String attemptedRoot;
  final ServiceManager Function(StackLayout)? serviceManagerFactory;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF0E7A4A),
    );

    return MaterialApp(
      title: 'StackPilot',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: colorScheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF4F7F5),
        fontFamily: 'Segoe UI',
      ),
      home: DashboardPage(
        layout: layout,
        attemptedRoot: attemptedRoot,
        serviceManagerFactory: serviceManagerFactory,
      ),
    );
  }
}
