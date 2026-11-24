import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'ui/screens/home_screen.dart';
import 'ui/theme/noven_colors.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  runApp(const NovenApp());
}

class NovenApp extends StatelessWidget {
  const NovenApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Noven',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: NovenColors.bg,
        colorScheme: const ColorScheme.dark(
          primary: NovenColors.accent,
          secondary: NovenColors.silver,
          surface: NovenColors.surface,
          onSurface: NovenColors.silver,
        ),
        sliderTheme: const SliderThemeData(
          trackHeight: 3,
          thumbShape: RoundSliderThumbShape(enabledThumbRadius: 5.5),
          overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
