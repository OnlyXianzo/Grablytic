import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/engine/engine_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/app_logger.dart';
import '../../../core/utils/download_config.dart';
import '../../../core/utils/offline_link_queue.dart';
import '../../../core/utils/playlist_selection.dart';
import '../../../providers/download_provider.dart';
import '../../../providers/settings_provider.dart';
import 'format_picker_screen.dart';
import 'playlist_selection_screen.dart';

/// Standalone share overlay root application (Seal/YTDLnis pattern).
///
/// Bootstrapped when [ShareActivity] is launched via `ACTION_SEND`.
/// Uses a transparent window/scaffold background with a rounded bottom card
/// hosting [FormatPickerScreen] or [PlaylistSelectionScreen].
class ShareOverlayApp extends ConsumerWidget {
  final String? initialUrl;

  const ShareOverlayApp({super.key, this.initialUrl});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    return MaterialApp(
      title: 'Grablytic Share',
      debugShowCheckedModeBanner: false,
      themeMode: settings.themeMode == AppThemeMode.system
          ? ThemeMode.system
          : settings.themeMode == AppThemeMode.light
          ? ThemeMode.light
          : ThemeMode.dark,
      theme: AppTheme.light().copyWith(
        scaffoldBackgroundColor: Colors.transparent,
      ),
      darkTheme: AppTheme.dark().copyWith(
        scaffoldBackgroundColor: Colors.transparent,
      ),
      home: ShareOverlayScreen(initialUrl: initialUrl),
    );
  }
}

class ShareOverlayScreen extends ConsumerStatefulWidget {
  final String? initialUrl;

  const ShareOverlayScreen({super.key, this.initialUrl});

  static String? extractUrl(String? text) {
    if (text == null || text.trim().isEmpty) return null;
    final match = RegExp(
      r"(https?://[\w\d:#@%/;$~()*&+-=?.\!\[\]]+)",
    ).firstMatch(text);
    return match?.group(0);
  }

  @override
  ConsumerState<ShareOverlayScreen> createState() => _ShareOverlayScreenState();
}

class _ShareOverlayScreenState extends ConsumerState<ShareOverlayScreen> {
  String? _sharedUrl;
  bool _isResolving = true;
  bool _autoStarted = false;
  StreamSubscription<String>? _streamSub;

  @override
  void initState() {
    super.initState();
    _resolveUrl();
  }

  @override
  void dispose() {
    _streamSub?.cancel();
    super.dispose();
  }

  void _finish() {
    if (!mounted) return;
    SystemNavigator.pop();
    try {
      const MethodChannel(
        'com.theonly.grablytic/engine',
      ).invokeMethod('activity/finish');
    } catch (_) {}
  }

  Future<void> _resolveUrl() async {
    // 1. Direct from entrypoint arguments
    final directUrl = ShareOverlayScreen.extractUrl(widget.initialUrl);
    if (directUrl != null && directUrl.isNotEmpty) {
      _onUrlResolved(directUrl);
      return;
    }

    // 2. Poll engine getSharedUrl
    try {
      final engine = ref.read(engineProvider);
      final fromEngine = await engine.getSharedUrl();
      if (fromEngine != null && fromEngine.isNotEmpty) {
        _onUrlResolved(fromEngine);
        return;
      }

      // 3. Fallback to stream with brief timeout
      _streamSub = engine.sharedUrlStream.listen((streamUrl) {
        final clean = ShareOverlayScreen.extractUrl(streamUrl);
        if (clean != null && clean.isNotEmpty) {
          _streamSub?.cancel();
          _onUrlResolved(clean);
        }
      });

      // Give native intent pump up to 1.5 seconds to deliver
      await Future.delayed(const Duration(milliseconds: 1500));
      if (!mounted) return;

      if (_sharedUrl == null) {
        final retry = await engine.getSharedUrl();
        if (retry != null && retry.isNotEmpty) {
          _onUrlResolved(retry);
          return;
        }
        setState(() => _isResolving = false);
      }
    } catch (e) {
      AppLogger.warn('Failed resolving shared URL: $e', tag: 'ShareOverlay');
      if (mounted) setState(() => _isResolving = false);
    }
  }

  Future<void> _onUrlResolved(String url) async {
    if (!mounted) return;
    final offline = await isDeviceOffline();
    if (!mounted) return;
    if (offline) {
      await ref
          .read(offlineQueueProvider.notifier)
          .addLink(url, source: 'share');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Offline: Shared link saved to queue')),
      );
      await Future.delayed(const Duration(milliseconds: 600));
      _finish();
      return;
    }

    final settings = ref.read(settingsProvider);
    if (settings.shareBehavior == 'auto' || settings.autoStartDownloadOnShare) {
      _triggerAutoDownload(url);
    } else {
      setState(() {
        _sharedUrl = url;
        _isResolving = false;
      });
    }
  }

  Future<void> _triggerAutoDownload(String url) async {
    if (_autoStarted || !mounted) return;
    _autoStarted = true;
    setState(() => _isResolving = false);

    final settings = ref.read(settingsProvider);
    final engine = ref.read(engineProvider);
    final notifier = ref.read(downloadProvider.notifier);

    final downloadId = const Uuid().v4();
    final config = <String, dynamic>{
      'container': settings.qualityCeiling == 'best' ? 'mkv' : 'mp4',
      'quality_ceiling': settings.qualityCeiling,
      'audio_only': settings.audioOnly,
      ...settingsDownloadConfig(settings),
    };

    try {
      final startRes = await engine.startDownload(
        url: url,
        downloadId: downloadId,
        config: config,
        networkType: 'wifi',
      );

      if (startRes['success'] == true) {
        notifier.addDownload(
          DownloadItem(
            id: downloadId,
            title: url,
            url: url,
            status: startRes['queued'] == true ? 'queued' : 'downloading',
            config: config,
            networkType: 'wifi',
          ),
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                startRes['queued'] == true
                    ? 'Queued — starts when a slot frees up'
                    : 'Auto-starting download from shared link',
              ),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } else {
        final errorMsg =
            startRes['error_message'] as String? ?? 'Could not start download';
        await engine.showErrorNotification(
          downloadId: downloadId,
          title: 'Download failed',
          error: errorMsg,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Auto-download failed: $errorMsg'),
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (e) {
      AppLogger.error('Auto-start download failed: $e', tag: 'ShareOverlay');
      await engine.showErrorNotification(
        downloadId: downloadId,
        title: 'Download failed',
        error: e.toString(),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Auto-download failed: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }

    // Dismiss overlay once auto-start completes or reports error
    await Future.delayed(const Duration(milliseconds: 600));
    _finish();
  }

  @override
  Widget build(BuildContext context) {
    if (_isResolving) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _finish();
        },
        child: const Scaffold(
          backgroundColor: Colors.transparent,
          body: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    final url = _sharedUrl;
    if (url == null || url.isEmpty) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _finish();
        },
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Center(
            child: Card(
              margin: const EdgeInsets.symmetric(horizontal: 32),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.link_off, size: 48, color: Colors.orange),
                    const SizedBox(height: 16),
                    const Text(
                      'No valid link received',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _finish,
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _finish();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            // Tap outside scrim to finish
            GestureDetector(
              onTap: _finish,
              behavior: HitTestBehavior.opaque,
              child: Container(
                color: Colors.transparent,
                width: double.infinity,
                height: double.infinity,
              ),
            ),
            // Floating bottom card with rounded top corners
            Align(
              alignment: Alignment.bottomCenter,
              child: FractionallySizedBox(
                heightFactor: 0.90,
                widthFactor: 1.0,
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(20),
                  ),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(20),
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 16,
                          spreadRadius: 4,
                        ),
                      ],
                    ),
                    child: Navigator(
                      onDidRemovePage: (page) {
                        _finish();
                      },
                      pages: [
                        MaterialPage(
                          child: isPlaylistUrl(url)
                              ? PlaylistSelectionScreen(url: url, title: url)
                              : FormatPickerScreen(url: url, title: url),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
