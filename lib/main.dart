import 'dart:async' show FutureRecord2, runZonedGuarded, unawaited;
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
import 'package:shared_preferences/shared_preferences.dart'
    show SharedPreferences;
import 'core/engine/engine_provider.dart' show setEngineDirs;
import 'core/utils/app_logger.dart';
import 'core/utils/crash_reporter.dart';
import 'core/utils/log_buffer.dart';
import 'core/utils/logging_observers.dart';
import 'core/utils/pending_report.dart';
import 'features/home/screens/share_overlay_screen.dart';

/// Route observer instance shared by [GrablyticApp].
final loggingNavigatorObserver = LoggingNavigatorObserver();

void main() {
  // Flutter requires the binding and runApp to live in the SAME zone.
  // Initializing the binding in the root zone and then calling runApp
  // inside runZonedGuarded associates the framework callbacks with the
  // root zone, so their errors are dispatched to a handler that does not
  // exist instead of the app's handler below — the crash reporter and
  // the auto-report silently missed exactly the errors they exist for.
  //
  // The whole startup path therefore runs inside the guarded zone. The
  // zone values that the startup code needs are produced before the
  // zone is entered, and the zone handler is installed by FlutterError
  // inside it.
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      await _bootstrap();
    },
    (error, stack) {
      try {
        AppLogger.fatal(
          'Uncaught zone error: $error',
          tag: 'global',
          error: error,
          stackTrace: stack,
        );
        unawaited(AppLogger.flushNow());
      } catch (_) {}
      // A failure here happened outside the framework's handlers (or
      // before they were installed), so it still needs to reach the
      // report queue — that is the only way the next launch can offer it.
      unawaited(_captureCrash(error, stack));
    },
  );
}

/// Startup work that must run inside the app's zone, after the binding
/// is initialized.
Future<void> _bootstrap() async {
  if (!kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  final prefs = await SharedPreferences.getInstance();
  // Both lookups are independent platform-channel round trips; awaiting
  // them in series made the first frame wait for the SUM of the two.
  final (appDir, cacheDir) = await (
    getApplicationDocumentsDirectory(),
    getTemporaryDirectory(),
  ).wait;
  await AppLogger.init(appDir.path, prefs);

  // Crash reporting: a sanitized report is written to disk locally, and a
  // GitHub issue is only ever filed with the user's say-so (the settings
  // switch, or the Send button). A failure to set this up must not stop the
  // app: `instance` stays null and every reporting surface degrades to
  // "unavailable" instead of throwing.
  try {
    final store = await PendingReportStore.open(appDir.path);
    CrashReporter.instance = CrashReporter(
      store: store,
      prefsLoader: CrashReporter.viewFromPrefs(
        () async => prefs.getBool('auto_crash_reporting') ?? false,
      ),
    );
  } catch (e) {
    AppLogger.warn('Crash reporting unavailable: $e', tag: 'reporting');
  }

  // Initialize in-memory log buffer and wire to AppLogger
  final logBuffer = LogBuffer.forThisPlatform();
  AppLogger.initBuffer(logBuffer);
  AppLogger.info(
    'App opened/started (build ${const String.fromEnvironment('GRABLYTIC_GIT_SHA', defaultValue: 'dev')})',
  );

  // Cap decoded-image memory. Flutter's default is 100 MiB of decoded
  // bytes — on a 2 GB phone that is a fifth of the heap held by cover art.
  // 40 MiB keeps a screenful of 360 px thumbs plus the open preview.
  PaintingBinding.instance.imageCache
    ..maximumSizeBytes = 40 << 20
    ..maximumSize = 250;

  final isWindows = !kIsWeb && Platform.isWindows;
  final ext = isWindows ? '.exe' : '';

  setEngineDirs(
    appDir.path,
    cacheDir.path,
    ffmpegPath: '${appDir.path}/bin/ffmpeg$ext',
    aria2cPath: '${appDir.path}/bin/aria2c$ext',
    denoPath:
        !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
        ? '${appDir.path}/bin/deno$ext'
        : null,
  );

  // Resolved BEFORE runApp on purpose: settingsProvider reads the whole
  // preference set once, so writing it afterwards would leave this session
  // on the legacy placeholder until the next launch. It only runs on a
  // fresh install, where the write is a one-off.
  if (!prefs.containsKey('downloadPath') ||
      prefs.getString('downloadPath') == '/Internal/Videos') {
    final defaultPath = await getDefaultDownloadPath();
    await prefs.setString('downloadPath', defaultPath);
  }

  // Global error boundaries (STEP 3A).
  //
  // `onFatal` captures and queues; it never touches the network. The old
  // version built a report and POSTed it inline, which meant every crash
  // paid a 20-second HTTP timeout during shutdown — and in a release build
  // (no token) it built a body and discarded it, so the next launch had no
  // idea anything had gone wrong.
  AppLogger.installGlobalErrorHandlers(
    onFatal: (error, stack) async {
      await _captureCrash(error, stack);
    },
  );

  runApp(
    ProviderScope(
      observers: [LoggingProviderObserver()],
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        logBufferProvider.overrideWithValue(logBuffer),
      ],
      child: const GrablyticApp(),
    ),
  );

  // One deferred attempt at the queue, after the first frame. Kept off the
  // startup path so a slow network cannot delay the UI, and gated inside on
  // the user's opt-in preference.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final reporter = CrashReporter.instance;
    if (reporter == null) return;
    unawaited(
      reporter.submitQueuedIfOptedIn().catchError(
            (Object e) => AppLogger.warn(
              'Queued report submission failed: $e',
              tag: 'reporting',
            ),
          ),
    );
  });
}

/// Records an unhandled failure for the next launch to offer.
///
/// Never throws: this runs inside error handlers, and a reporting failure
/// there would replace the original crash with a confusing second one.
Future<void> _captureCrash(Object error, StackTrace? stack) async {
  final reporter = CrashReporter.instance;
  if (reporter == null) return;
  try {
    final report = await reporter.recordCrash(error, stack);
    if (report != null) {
      AppLogger.fatal(
        'Crash captured for reporting (${report.fingerprint})',
        tag: 'reporting',
      );
    }
  } catch (_) {
    // Nothing to do: the log line above is the fallback.
  }
}

class GrablyticApp extends ConsumerWidget {
  const GrablyticApp({super.key});

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
    // Eagerly activate log ingestion so engine logs stream into LogBuffer
    ref.watch(logIngesterProvider);
    final settings = ref.watch(settingsProvider);
    return MaterialApp(
      title: 'Grablytic',
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

/// Dedicated Dart entrypoint for [ShareActivity] (Seal/YTDLnis overlay pattern).
@pragma('vm:entry-point')
void shareMain([List<String>? args]) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  // Parallelize the three independent platform-channel round-trips: prefs
  // + two dirs. On the share overlay (cold start) this shaves ~80–150 ms
  // off the first frame vs sequential awaits, with no visual change.
  final prefsFuture = SharedPreferences.getInstance();
  final appDirFuture = getApplicationDocumentsDirectory();
  final cacheDirFuture = getTemporaryDirectory();
  final prefs = await prefsFuture;
  final appDir = await appDirFuture;
  final cacheDir = await cacheDirFuture;
  await AppLogger.init(appDir.path, prefs);

  final logBuffer = LogBuffer(maxEntries: 5000);
  AppLogger.initBuffer(logBuffer);
  AppLogger.info('Share entrypoint opened', tag: 'shareMain');

  final isWindows = !kIsWeb && Platform.isWindows;
  final ext = isWindows ? '.exe' : '';

  setEngineDirs(
    appDir.path,
    cacheDir.path,
    ffmpegPath: '${appDir.path}/bin/ffmpeg$ext',
    aria2cPath: '${appDir.path}/bin/aria2c$ext',
    denoPath:
        !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
        ? '${appDir.path}/bin/deno$ext'
        : null,
  );

  if (!prefs.containsKey('downloadPath') ||
      prefs.getString('downloadPath') == '/Internal/Videos') {
    final defaultPath = await getDefaultDownloadPath();
    await prefs.setString('downloadPath', defaultPath);
  }

  runApp(
    ProviderScope(
      observers: [LoggingProviderObserver()],
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        logBufferProvider.overrideWithValue(logBuffer),
      ],
      child: ShareOverlayApp(
        initialUrl: (args != null && args.isNotEmpty) ? args.first : null,
      ),
    ),
  );
}
