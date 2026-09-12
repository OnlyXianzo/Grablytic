import 'dart:async' show runZonedGuarded, unawaited;
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
import 'providers/log_provider.dart';
import 'package:shared_preferences/shared_preferences.dart' show SharedPreferences;
import 'core/engine/engine_provider.dart' show setEngineDirs;
import 'core/utils/app_logger.dart';
import 'core/utils/log_buffer.dart';
import 'core/utils/github_reporter.dart';
import 'core/utils/logging_observers.dart';

/// Route observer instance shared by [TrueStreamApp].
final loggingNavigatorObserver = LoggingNavigatorObserver();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  final prefs = await SharedPreferences.getInstance();
  final appDir = await getApplicationDocumentsDirectory();
  await AppLogger.init(appDir.path, prefs);

  // Initialize in-memory log buffer and wire to AppLogger
  final logBuffer = LogBuffer(maxEntries: 5000);
  AppLogger.initBuffer(logBuffer);
  AppLogger.info(
      'App opened/started (build ${const String.fromEnvironment('TRUESTREAM_GIT_SHA', defaultValue: 'dev')})');

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

  // Global error boundaries (STEP 3A). Anonymous by default: auto-report to
  // GitHub only when the user explicitly opts in via settings.
  AppLogger.installGlobalErrorHandlers(
    onFatal: (error, stack) async {
      try {
        final autoReport = prefs.getBool('auto_crash_reporting') ?? false;
        if (!autoReport) return;
        final reporter = GithubReporter();
        final result = await reporter.reportCrash(error, stack);
        AppLogger.info(
          'Auto-report finished: ${result.status.name}${result.url != null ? ' ${result.url}' : ''}',
          tag: 'github-reporter',
        );
      } catch (_) {
        // Reporting must never crash the crash handler.
      }
    },
  );

  runZonedGuarded(
    () {
      runApp(
        ProviderScope(
          observers: [LoggingProviderObserver()],
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            logBufferProvider.overrideWithValue(logBuffer),
          ],
          child: const TrueStreamApp(),
        ),
      );
    },
    (error, stack) {
      try {
        AppLogger.fatal('Uncaught zone error: $error',
            tag: 'global', error: error, stackTrace: stack);
        unawaited(AppLogger.flushNow());
      } catch (_) {}
    },
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
      navigatorObservers: [loggingNavigatorObserver],
      home: settings.onboardingCompleted
          ? const AppShell()
          : const OnboardingScreen(),
    );
  }
}
