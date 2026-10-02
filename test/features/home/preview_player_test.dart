import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grablytic/core/engine/engine_provider.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/features/home/screens/format_picker_screen.dart';
import 'package:grablytic/providers/settings_provider.dart';

class _PreviewAvailableMockEngine extends MockEngineService {
  @override
  Future<Map<String, dynamic>> getFormats({
    required String url,
    required Map<String, dynamic> config,
  }) async {
    return {
      'success': true,
      'title': 'Previewable Video',
      'duration_seconds': 120,
      'thumbnail_url': 'https://example.com/thumb.jpg',
      'recommended_video_format_id': '137',
      'recommended_audio_format_id': '140',
      'recommended_muxed_format_id': '18',
      'preview_stream': {
        'url': 'https://example.com/preview_360p.mp4',
        'headers': {'User-Agent': 'TestUA', 'Cookie': 'test=1'},
        'format_id': '18',
        'height': 360,
        'width': 640,
        'ext': 'mp4',
      },
      'formats': [
        {
          'format_id': '18',
          'ext': 'mp4',
          'vcodec': 'avc1',
          'acodec': 'mp4a',
          'height': 360,
          'width': 640,
          'stream_type': 'muxed',
        },
      ],
    };
  }
}

class _PreviewUnavailableMockEngine extends MockEngineService {
  @override
  Future<Map<String, dynamic>> getFormats({
    required String url,
    required Map<String, dynamic> config,
  }) async {
    return {
      'success': true,
      'title': 'Audio Track No Preview',
      'duration_seconds': 180,
      'thumbnail_url': '',
      'recommended_video_format_id': null,
      'recommended_audio_format_id': '140',
      'recommended_muxed_format_id': null,
      'preview_stream': null,
      'formats': [
        {
          'format_id': '140',
          'ext': 'm4a',
          'vcodec': 'none',
          'acodec': 'mp4a',
          'stream_type': 'audio',
        },
      ],
    };
  }
}

Future<SharedPreferences> _prefs() async {
  SharedPreferences.setMockInitialValues({'onboardingCompleted': true});
  return SharedPreferences.getInstance();
}

void main() {
  group('T08: Pre-download in-app preview tests', () {
    testWidgets(
      'shows play icon on thumbnail when preview_stream is available',
      (tester) async {
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final prefs = await _prefs();
        final mockEngine = _PreviewAvailableMockEngine();

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(prefs),
              engineProvider.overrideWithValue(mockEngine),
            ],
            child: const MaterialApp(
              home: FormatPickerScreen(
                url: 'https://example.com/watch?v=previewable',
                title: 'Previewable Video',
              ),
            ),
          ),
        );

        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // Should show play icon overlay on thumbnail
        expect(find.byIcon(Icons.play_arrow), findsOneWidget);
        // Download button must remain completely unblocked
        expect(find.text('Download Now'), findsOneWidget);
      },
    );

    testWidgets(
      'shows "Preview unavailable" silently when preview_stream is null without blocking picker',
      (tester) async {
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final prefs = await _prefs();
        final mockEngine = _PreviewUnavailableMockEngine();

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(prefs),
              engineProvider.overrideWithValue(mockEngine),
            ],
            child: const MaterialApp(
              home: FormatPickerScreen(
                url: 'https://example.com/track/123',
                title: 'Audio Track',
              ),
            ),
          ),
        );

        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // Should show "Preview unavailable" text silently
        expect(find.text('Preview unavailable'), findsOneWidget);
        // Download button must remain completely visible and usable
        expect(find.text('Download Now'), findsOneWidget);
      },
    );
  });
}
