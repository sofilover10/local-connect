import 'package:flutter/material.dart';

class AppTheme {
  // Brand Color Seeds
  static const Color primaryTeal = Color(0xFF0E7A8A);
  static const Color mutedOlive = Color(0xFF3F6212);
  static const Color warningAmber = Color(0xFFCA8A04);

  static final ThemeData light = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: const Color(0xFFFAF9F6), // Warm Stone
    colorScheme: const ColorScheme(
      brightness: Brightness.light,
      primary: primaryTeal,
      onPrimary: Colors.white,
      primaryContainer: Color(0xFFE0F2FE),
      onPrimaryContainer: Color(0xFF0369A1),
      secondary: mutedOlive,
      onSecondary: Colors.white,
      surface: Colors.white,
      onSurface: Color(0xFF0F172A), // Slate 900
      surfaceContainerHighest: Color(0xFFF1F5F9), // Slate 100
      onSurfaceVariant: Color(0xFF64748B), // Slate 500
      outline: Color(0xFFE2E8F0),
      error: Color(0xFFB3261E), // Semantic Error Red
      onError: Colors.white,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.white,
      foregroundColor: Color(0xFF0F172A),
      elevation: 0,
    ),
    cardTheme: const CardThemeData(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        side: BorderSide(color: Color(0xFFE2E8F0), width: 1),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFFF1F5F9),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE2E8F0), width: 1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: primaryTeal, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: primaryTeal,
      unselectedLabelColor: Color(0xFF64748B),
      indicatorColor: primaryTeal,
    ),
  );

  static final ThemeData dark = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: const Color(0xFF0F172A), // Slate 900
    colorScheme: const ColorScheme(
      brightness: Brightness.dark,
      primary: Color(0xFF14B8A6), // Muted Teal
      onPrimary: Color(0xFF0F172A),
      primaryContainer: primaryTeal,
      onPrimaryContainer: Color(0xFFCCFBF1),
      secondary: mutedOlive, // Kept Muted Olive
      onSecondary: Colors.white, // Contrast 6.6:1
      surface: Color(0xFF1E293B), // Slate 800
      onSurface: Color(0xFFE2E8F0), // Slate 200
      surfaceContainerHighest: Color(0xFF334155), // Slate 700
      onSurfaceVariant: Color(0xFF94A3B8), // Slate 400
      outline: Color(0xFF334155),
      error: Color(0xFFF2B8B5), // Accessible error red
      onError: Color(0xFF601410),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF1E293B),
      foregroundColor: Color(0xFFF8FAFC),
      elevation: 0,
    ),
    cardTheme: const CardThemeData(
      color: Color(0xFF1E293B),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        side: BorderSide(color: Color(0xFF334155), width: 1),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFF0F172A),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF334155), width: 1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF14B8A6), width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: Color(0xFF14B8A6),
      unselectedLabelColor: Color(0xFF94A3B8),
      indicatorColor: Color(0xFF14B8A6),
    ),
  );
}
