import 'dart:async' show FutureRecord2, runZonedGuarded, unawaited;
import 'dart:convert';
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
import 'core/utils/log_buffer.dart';
import 'core/utils/crash_reports.dart';
import 'core/utils/logging_observers.dart';
import 'core/utils/pending_report.dart';
import 'features/home/screens/share_overlay_screen.dart';

/// Route observer instance shared by [GrablyticApp].
final loggingNavigatorObserver = LoggingNavigatorObserver();
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();
/// Key the previous shared-preferences based crash slot lived under.
///
/// Kept only so an install that queued a crash under the old scheme can
/// hand it to the new queue once. See [_migrateLegacyCrash].
const _pendingCrashKey = 'pending_crash_report';

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
        AppLogger.reportUncaught(error, stack);
      } catch (_) {}
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

  // Crash capture: a redacted draft is written under `<app>/reports` and a
  // GitHub issue is only ever considered later (or with the user's say-so).
  // A failure to set this up must not stop the app: `instance` stays null
  // and every reporting surface degrades to "unavailable".
  try {
    final store = await CrashReports.openStore(appDir.path);
    CrashReports.instance = CrashReports(
      store: store,
      autoSendLoader: () async =>
          prefs.getBool('auto_crash_reporting') ?? false,
    );
    await _migrateLegacyCrash(store, prefs);
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
  // `onFatal` captures and returns. It used to build a body, search for a
  // duplicate AND post the issue from inside the handler, which is a
  // 20-second worst case during shutdown — and on a stock build (no token)
  // it discarded the body, so nothing reached the next launch when the
  // user had automatic reporting off, which is everyone.
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
  // One deferred attempt at the queue, after the first frame. Off the
  // startup path so a slow network cannot delay the UI, and gated inside on
  // the user's opt-in preference (and on the build having a token at all).
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final reports = CrashReports.instance;
    if (reports == null) return;
    unawaited(
      reports.submitQueuedIfOptedIn().catchError(
        (Object e) => AppLogger.warn('Queued report submission failed: $e',
            tag: 'reporting'),
      ),
    );
  });
}

/// Records an unhandled failure for the next launch to offer.
///
/// Never throws: this runs inside error handlers, where a reporting failure
/// would replace the original crash with a confusing second one.
Future<void> _captureCrash(Object error, StackTrace? stack) async {
  final reports = CrashReports.instance;
  if (reports == null) return;
  try {
    final report = await reports.capture(error, stack);
    if (report != null) {
      AppLogger.fatal(
        'Crash captured for reporting (${report.fingerprint})',
        tag: 'reporting',
      );
    }
  } on Exception catch (e) {
    AppLogger.warn('Crash capture failed: $e', tag: 'reporting');
  }
}

/// Moves a crash queued by the old preferences-based scheme into the file
/// queue, once.
///
/// Before this, a crash was stored as a single JSON string under
/// `pending_crash_report` and only when automatic reporting was already
/// on. Anyone who updated with one sitting there should still see it; after
/// the move the old key is deleted so it is not offered twice.
Future<void> _migrateLegacyCrash(
  PendingReportStore? store,
  SharedPreferences prefs,
) async {
  if (store == null) return;
  final raw = prefs.getString(_pendingCrashKey);
  if (raw == null || raw.isEmpty) return;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      await prefs.remove(_pendingCrashKey);
      return;
    }
    final body = decoded['body']?.toString() ?? '';
    if (body.isEmpty) {
      await prefs.remove(_pendingCrashKey);
      return;
    }
    final fingerprint = decoded['fingerprint']?.toString() ?? '';
    final captured =
        DateTime.tryParse(decoded['captured_at']?.toString() ?? '') ??
            DateTime.now().subtract(const Duration(minutes: 1));
    await store.add(PendingReport(
      id: 'legacy-${fingerprint.isEmpty ? 'anon' : fingerprint}',
      fingerprint: fingerprint,
      category: ReportCategory.crash,
      title: decoded['title']?.toString() ?? '[Crash] Problem report',
      summary: 'The app encountered a problem and restarted.',
      body: body,
      createdAt: captured,
      source: 'auto',
    ));
    await prefs.remove(_pendingCrashKey);
    AppLogger.info('Imported a pending crash from the old slot',
        tag: 'reporting');
  } on Exception catch (e) {
    AppLogger.warn('Could not import the old pending crash: $e',
        tag: 'reporting');
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
      navigatorKey: appNavigatorKey,
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
