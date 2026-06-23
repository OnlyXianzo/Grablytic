import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'core/theme/app_theme.dart';
import 'core/engine/engine_provider.dart';
import 'features/onboarding/screens/onboarding_screen.dart';
import 'features/shell/screens/app_shell.dart';
import 'providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart' show SharedPreferences;
import 'core/engine/engine_provider.dart' show setEngineDirs;
import 'core/utils/app_logger.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  final prefs = await SharedPreferences.getInstance();
  final appDir = await getApplicationDocumentsDirectory();
  await AppLogger.init(appDir.path, prefs);
  AppLogger.info('App opened/started');
  final cacheDir = await getTemporaryDirectory();

  final isWindows = !kIsWeb && Platform.isWindows;
  final ext = isWindows ? '.exe' : '';

  setEngineDirs(
    appDir.path,
    cacheDir.path,
    ffmpegPath: '${appDir.path}/bin/ffmpeg$ext',
    aria2cPath: '${appDir.path}/bin/aria2c$ext',
    denoPath: !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
        ? '${appDir.path}/bin/deno$ext'
        : null,
  );

  // Set professional industrial-grade download path if unset or using the dummy path
  if (!prefs.containsKey('downloadPath') || prefs.getString('downloadPath') == '/Internal/Videos') {
    final defaultPath = await getDefaultDownloadPath();
    await prefs.setString('downloadPath', defaultPath);
  }

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
      child: const TrueStreamApp(),
    ),
  );
}

class TrueStreamApp extends ConsumerWidget {
  const TrueStreamApp({super.key});

  ThemeMode _mapThemeMode(AppThemeMode mode) {
    switch (mode) {
      case AppThemeMode.system:
        return ThemeMode.system;
      case AppThemeMode.light:
        return ThemeMode.light;
      case AppThemeMode.dark:
        return ThemeMode.dark;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    return MaterialApp(
      title: 'TrueStream',
      debugShowCheckedModeBanner: false,
      themeMode: _mapThemeMode(settings.themeMode),
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: settings.onboardingCompleted
          ? const AppShell()
          : const OnboardingScreen(),
    );
  }
}
