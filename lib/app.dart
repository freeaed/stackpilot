import 'package:flutter/material.dart';

import 'core/app_preferences.dart';
import 'core/service_manager.dart';
import 'core/stack_layout.dart';
import 'ui/dashboard.dart';

class StackPilotApp extends StatelessWidget {
  const StackPilotApp({
    super.key,
    required this.layout,
    required this.attemptedRoot,
    this.serviceManagerFactory,
    this.preferences = AppPreferences.empty,
    this.preferencesStore,
  });

  final StackLayout? layout;
  final String attemptedRoot;
  final ServiceManager Function(StackLayout)? serviceManagerFactory;
  final AppPreferences preferences;
  final AppPreferencesStore? preferencesStore;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF0E7A4A),
    );
    final base = ThemeData(
      colorScheme: colorScheme,
      useMaterial3: true,
      fontFamily: 'Segoe UI',
    );

    return MaterialApp(
      title: 'StackPilot',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        scaffoldBackgroundColor: const Color(0xFFF4F7F5),
        dividerTheme: const DividerThemeData(
          color: Color(0xFFE1E8E4),
          thickness: 1,
          space: 1,
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          color: Colors.white,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: Color(0xFFE1E8E4)),
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF14352A),
          contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13),
          actionTextColor: const Color(0xFF9BE3C0),
          insetPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 12,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(9),
            borderSide: const BorderSide(color: Color(0xFFD4DFD8)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(9),
            borderSide: const BorderSide(color: Color(0xFFD4DFD8)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(9),
            borderSide: BorderSide(color: colorScheme.primary, width: 1.6),
          ),
          helperStyle: const TextStyle(
            fontSize: 11.5,
            color: Color(0xFF7A8880),
          ),
          helperMaxLines: 3,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(9),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(9),
            ),
            side: const BorderSide(color: Color(0xFFCBD9D0)),
          ),
        ),
        tooltipTheme: TooltipThemeData(
          waitDuration: const Duration(milliseconds: 450),
          decoration: BoxDecoration(
            color: const Color(0xFF14352A),
            borderRadius: BorderRadius.circular(6),
          ),
          textStyle: const TextStyle(color: Colors.white, fontSize: 11.5),
        ),
      ),
      home: DashboardPage(
        layout: layout,
        attemptedRoot: attemptedRoot,
        serviceManagerFactory: serviceManagerFactory,
        preferences: preferences,
        preferencesStore: preferencesStore,
      ),
    );
  }
}
