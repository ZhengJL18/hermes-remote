import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'screens/chat_screen.dart';
import 'screens/settings_screen.dart';

class HermesColors {
  static const primary = Color(0xFFDB704B);       // Hermes 桌面端主橙
  static const primaryLight = Color(0xFFFF8C42);  // 亮橙
  static const primaryVariant = Color(0xFFC08532); // 金橙
  static const darkBg = Color(0xFF0D0D0E);
  static const darkSurface = Color(0xFF141414);
  static const darkSurface2 = Color(0xFF161618);
  static const textPrimary = Color(0xFFF3F3F3);
  static const textSecondary = Color(0xFFA0A0A5);
  static const success = Color(0xFF00BB7F);
  static const error = Color(0xFFCF2D56);
}

final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.system);

class HermesApp extends ConsumerWidget {
  const HermesApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp(
      title: 'Hermes',
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      darkTheme: _buildDarkTheme(),
      theme: _buildLightTheme(),
      home: const ChatScreen(),
    );
  }

  ThemeData _buildLightTheme() => ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: ColorScheme.fromSeed(
      seedColor: HermesColors.primary,
      brightness: Brightness.light,
    ),
    scaffoldBackgroundColor: const Color(0xFFF8F9FA),
    appBarTheme: const AppBarTheme(elevation: 0, centerTitle: false, scrolledUnderElevation: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFFEEEEF0),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    ),
    cardTheme: CardThemeData(color: Colors.white, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
    dividerTheme: const DividerThemeData(color: Color(0xFFE0E0E0), thickness: 0.5),
  );

  ThemeData _buildDarkTheme() => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: const ColorScheme.dark(
      primary: HermesColors.primary,
      secondary: HermesColors.primaryVariant,
      surface: HermesColors.darkSurface,
      surfaceContainerHighest: HermesColors.darkSurface2,
      error: HermesColors.error,
      onPrimary: Colors.white,
      onSecondary: Colors.white,
      onSurface: HermesColors.textPrimary,
      onSurfaceVariant: HermesColors.textSecondary,
    ),
    scaffoldBackgroundColor: HermesColors.darkBg,
    appBarTheme: const AppBarTheme(backgroundColor: HermesColors.darkSurface, foregroundColor: HermesColors.textPrimary, elevation: 0, centerTitle: false, scrolledUnderElevation: 1),
    inputDecorationTheme: InputDecorationTheme(filled: true, fillColor: HermesColors.darkSurface2, border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none), contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
    cardTheme: CardThemeData(color: HermesColors.darkSurface2, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
    textTheme: const TextTheme(bodyLarge: TextStyle(fontSize: 16, height: 1.5, color: HermesColors.textPrimary), bodyMedium: TextStyle(fontSize: 14, height: 1.5, color: HermesColors.textSecondary), bodySmall: TextStyle(fontSize: 12, color: HermesColors.textSecondary)),
    dividerTheme: const DividerThemeData(color: Color(0xFF2A2A2D), thickness: 0.5),
  );
}
