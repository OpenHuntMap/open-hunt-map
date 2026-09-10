import 'package:flutter/material.dart';

import 'map/map_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OpenWoodsMapApp());
}

class OpenWoodsMapApp extends StatelessWidget {
  const OpenWoodsMapApp({super.key});

  @override
  Widget build(BuildContext context) {
    const forest = Color(0xFF1B4332);
    const cream = Color(0xFFFFFBF0);
    final scheme = ColorScheme.fromSeed(
      seedColor: forest,
      brightness: Brightness.light,
      surface: cream,
    ).copyWith(
      primary: forest,
      secondary: const Color(0xFF52796F),
      surface: cream,
    );
    return MaterialApp(
      title: 'OpenWoodsMap',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor: cream,
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: forest,
          foregroundColor: Colors.white,
          centerTitle: false,
        ),
        cardTheme: const CardThemeData(
          color: Color(0xFFFFFDF7),
          elevation: 1,
        ),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(),
        ),
      ),
      home: const MapShell(),
    );
  }
}
