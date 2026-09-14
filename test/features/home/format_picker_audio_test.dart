import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grablytic/core/engine/engine_provider.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/features/home/screens/format_picker_screen.dart';
import 'package:grablytic/providers/settings_provider.dart';

class _SoundCloudMockEngine extends MockEngineService {
  Map<String, dynamic>? lastStartDownloadConfig;

  @override
  Future<Map<String, dynamic>> getFormats({
    required String url,
    required Map<String, dynamic> config,
  }) async {
    return {
      'success': true,
      'title': 'SoundCloud Audio Track',
      'duration_seconds': 223,
      'thumbnail_url': null,
      'is_live': false,
      'is_playlist': false,
      'recommended_video_format_id': null,
      'recommended_audio_format_id': 'hls_aac_160k',
      'recommended_muxed_format_id': null,
      'formats': [
        {
          'format_id': 'hls_mp3_0_1',
          'ext': 'mp3',
          'vcodec': 'none',
          'acodec': 'mp3',
          'height': null,
          'width': null,
          'fps': null,
          'tbr': 128.0,
          'abr': 128.0,
          'vbr': 0.0,
          'filesize': 3578048,
          'filesize_is_estimate': true,
          'is_hdr': false,
          'dynamic_range': 'SDR',
          'stream_type': 'audio',
        },
        {
          'format_id': 'hls_aac_160k',
          'ext': 'm4a',
          'vcodec': 'none',
          'acodec': 'mp4a.40.2',
          'height': null,
          'width': null,
          'fps': null,
          'tbr': 160.0,
          'abr': 160.0,
          'vbr': 0.0,
          'filesize': 4472559,
          'filesize_is_estimate': true,
          'is_hdr': false,
          'dynamic_range': 'SDR',
          'stream_type': 'audio',
        },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> startDownload({
    required String url,
    required String downloadId,
    required Map<String, dynamic> config,
    required String networkType,
  }) async {
    lastStartDownloadConfig = config;
    return {
      'success': true,
      'queued': false,
      'download_id': downloadId,
    };
  }
}

class _VideoAudioMockEngine extends MockEngineService {
  Map<String, dynamic>? lastStartDownloadConfig;

  @override
  Future<Map<String, dynamic>> startDownload({
    required String url,
    required String downloadId,
    required Map<String, dynamic> config,
    required String networkType,
  }) async {
    lastStartDownloadConfig = config;
    return {
      'success': true,
      'queued': false,
      'download_id': downloadId,
    };
  }
}

Future<SharedPreferences> _prefs() async {
  SharedPreferences.setMockInitialValues({'onboardingCompleted': true});
  return SharedPreferences.getInstance();
}

void main() {
  group('FormatPickerScreen Audio & SoundCloud Tests', () {
    testWidgets('pure audio source (SoundCloud) defaults to single audio selection and passes audio_only: true', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final prefs = await _prefs();
      final mockEngine = _SoundCloudMockEngine();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWithValue(mockEngine),
          ],
          child: const MaterialApp(
            home: FormatPickerScreen(
              url: 'https://soundcloud.com/artist/track',
              title: 'SoundCloud Track',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Video streams section should NOT be present
      expect(find.textContaining('VIDEO STREAMS'), findsNothing);
      expect(find.textContaining('COMBINED STREAMS'), findsNothing);

      // Audio streams section SHOULD be present
      expect(find.textContaining('AUDIO STREAMS'), findsOneWidget);

      // Preferred container should default to an audio container (m4a)
      expect(find.text('M4A (Recommended)'), findsOneWidget);

      // Tap Download Now button
      final downloadBtn = find.widgetWithText(ElevatedButton, 'Download Now');
      expect(downloadBtn, findsOneWidget);
      await tester.tap(downloadBtn);
      await tester.pumpAndSettle();

      // Verify engine received audio_only: true and explicit_audio_format_id
      expect(mockEngine.lastStartDownloadConfig, isNotNull);
      expect(mockEngine.lastStartDownloadConfig!['audio_only'], isTrue);
      expect(mockEngine.lastStartDownloadConfig!['explicit_format_id'], isNull);
      expect(mockEngine.lastStartDownloadConfig!['explicit_audio_format_id'], 'hls_aac_160k');
      expect(mockEngine.lastStartDownloadConfig!['container'], 'm4a');
    });

    testWidgets('video+audio source switches to clean audio-only mode via segmented button', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final prefs = await _prefs();
      final mockEngine = _VideoAudioMockEngine();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWithValue(mockEngine),
          ],
          child: const MaterialApp(
            home: FormatPickerScreen(
              url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
              title: 'Sample Video',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Initially Video + Audio is selected and VIDEO STREAMS is visible
      expect(find.text('Video + Audio'), findsOneWidget);
      expect(find.text('Audio Only'), findsOneWidget);
      expect(find.textContaining('VIDEO STREAMS'), findsOneWidget);
      expect(find.text('MKV (Recommended)'), findsOneWidget);

      // Tap 'Audio Only' segment
      await tester.tap(find.text('Audio Only'));
      await tester.pumpAndSettle();

      // VIDEO STREAMS is now hidden in Audio Only mode
      expect(find.textContaining('VIDEO STREAMS'), findsNothing);
      expect(find.textContaining('AUDIO STREAMS'), findsOneWidget);

      // Preferred container switched to audio container
      expect(find.text('M4A (Recommended)'), findsOneWidget);

      // Tap Download Now
      final downloadBtn = find.widgetWithText(ElevatedButton, 'Download Now');
      expect(downloadBtn, findsOneWidget);
      await tester.tap(downloadBtn);
      await tester.pumpAndSettle();

      // Engine receives audio_only: true with explicit_format_id: null
      expect(mockEngine.lastStartDownloadConfig, isNotNull);
      expect(mockEngine.lastStartDownloadConfig!['audio_only'], isTrue);
      expect(mockEngine.lastStartDownloadConfig!['explicit_format_id'], isNull);
      expect(mockEngine.lastStartDownloadConfig!['explicit_audio_format_id'], isNotNull);
      expect(mockEngine.lastStartDownloadConfig!['container'], 'm4a');
    });
  });
}
