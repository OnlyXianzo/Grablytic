import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grablytic/core/engine/engine_provider.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/core/utils/format_selector.dart';
import 'package:grablytic/core/utils/picker_session_state.dart';
import 'package:grablytic/features/home/screens/format_picker_screen.dart';
import 'package:grablytic/providers/settings_provider.dart';

class _ToggleTestMockEngine extends MockEngineService {
  Map<String, dynamic>? lastStartDownloadConfig;

  @override
  Future<Map<String, dynamic>> getFormats({
    required String url,
    required Map<String, dynamic> config,
  }) async {
    return {
      'success': true,
      'title': 'Test Media Title',
      'duration': 600, // 10 minutes
      'duration_seconds': 600,
      'thumbnail_url': null,
      'is_live': false,
      'is_playlist': false,
      'recommended_video_format_id': '137',
      'recommended_audio_format_id': '140',
      'recommended_muxed_format_id': null,
      'formats': [
        {
          'format_id': '137',
          'ext': 'mp4',
          'vcodec': 'avc1.640028',
          'acodec': 'none',
          'height': 1080,
          'width': 1920,
          'fps': 30.0,
          'tbr': 4000.0,
          'filesize': 5000000,
          'dynamic_range': 'SDR',
          'stream_type': 'video',
        },
        {
          'format_id': '136',
          'ext': 'mp4',
          'vcodec': 'avc1.4d401f',
          'acodec': 'none',
          'height': 720,
          'width': 1280,
          'fps': 30.0,
          'tbr': 2000.0,
          'filesize': 3000000,
          'dynamic_range': 'SDR',
          'stream_type': 'video',
        },
        {
          'format_id': '140',
          'ext': 'm4a',
          'vcodec': 'none',
          'acodec': 'mp4a.40.2',
          'height': null,
          'width': null,
          'fps': null,
          'tbr': 128.0,
          'abr': 128.0,
          'filesize': 1000000,
          'dynamic_range': null,
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
    return {'success': true, 'queued': false, 'download_id': downloadId};
  }
}

Future<SharedPreferences> _prefs() async {
  SharedPreferences.setMockInitialValues({'onboardingCompleted': true});
  return SharedPreferences.getInstance();
}

void main() {
  setUp(() {
    PickerSessionState.instance.reset();
  });

  tearDown(() {
    PickerSessionState.instance.reset();
  });

  group('T03 Unit Tests: parseTimeToSeconds & targetHeightForCeiling', () {
    test('parseTimeToSeconds parses valid time formats', () {
      expect(FormatPickerScreen.parseTimeToSeconds('0'), 0);
      expect(FormatPickerScreen.parseTimeToSeconds('45'), 45);
      expect(FormatPickerScreen.parseTimeToSeconds('01:30'), 90);
      expect(FormatPickerScreen.parseTimeToSeconds('10:05'), 605);
      expect(FormatPickerScreen.parseTimeToSeconds('01:02:03'), 3723);
      expect(FormatPickerScreen.parseTimeToSeconds('00:00'), 0);
    });

    test('parseTimeToSeconds rejects invalid formats', () {
      expect(FormatPickerScreen.parseTimeToSeconds(''), isNull);
      expect(FormatPickerScreen.parseTimeToSeconds('abc'), isNull);
      expect(FormatPickerScreen.parseTimeToSeconds('-5'), isNull);
      expect(
        FormatPickerScreen.parseTimeToSeconds('01:60'),
        isNull,
      ); // 60 seconds invalid
      expect(FormatPickerScreen.parseTimeToSeconds('01:75'), isNull);
      expect(
        FormatPickerScreen.parseTimeToSeconds('01:60:00'),
        isNull,
      ); // 60 mins invalid
    });

    test(
      'targetHeightForCeiling returns correct heights including 2160p and 2k aliases',
      () {
        expect(targetHeightForCeiling('4k', 'default'), 2160);
        expect(targetHeightForCeiling('2160p', 'default'), 2160);
        expect(targetHeightForCeiling('4K', 'default'), 2160);
        expect(targetHeightForCeiling('1440p', 'default'), 1440);
        expect(targetHeightForCeiling('2k', 'default'), 1440);
        expect(targetHeightForCeiling('1080p', 'default'), 1080);
        expect(targetHeightForCeiling('720p', 'default'), 720);
        expect(targetHeightForCeiling('480p', 'default'), 480);
        expect(targetHeightForCeiling('preset_480p', 'preset_480p'), 480);
        expect(targetHeightForCeiling('360p', 'default'), 360);
        expect(targetHeightForCeiling('best', 'default'), 99999);
      },
    );

    test('PickerSessionState retains and resets session values', () {
      final session = PickerSessionState.instance;
      expect(session.qualityCeiling, isNull);
      expect(session.embedSubtitles, isNull);
      expect(session.audioOnly, isNull);
      expect(session.clipEnabled, isFalse);
      expect(session.clipStart, isEmpty);
      expect(session.clipEnd, isEmpty);

      session.qualityCeiling = '1080p';
      session.embedSubtitles = true;
      session.audioOnly = false;
      session.clipEnabled = true;
      session.clipStart = '00:10';
      session.clipEnd = '01:00';

      expect(session.qualityCeiling, '1080p');
      expect(session.embedSubtitles, isTrue);
      expect(session.audioOnly, isFalse);
      expect(session.clipEnabled, isTrue);
      expect(session.clipStart, '00:10');
      expect(session.clipEnd, '01:00');

      session.reset();
      expect(session.qualityCeiling, isNull);
      expect(session.embedSubtitles, isNull);
      expect(session.audioOnly, isNull);
      expect(session.clipEnabled, isFalse);
      expect(session.clipStart, isEmpty);
      expect(session.clipEnd, isEmpty);
    });
  });

  group('T03 Widget Tests: Picker-Integrated Toggles', () {
    testWidgets('renders inline toggles and retains session state', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Pre-seed session state
      PickerSessionState.instance.qualityCeiling = '720p';
      PickerSessionState.instance.embedSubtitles = true;

      final prefs = await _prefs();
      final mockEngine = _ToggleTestMockEngine();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWithValue(mockEngine),
          ],
          child: const MaterialApp(
            home: FormatPickerScreen(
              url: 'https://www.youtube.com/watch?v=inline_toggles',
              title: 'Toggles Test',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify Quality Ceiling and Subtitles are visible
      expect(find.text('Quality Ceiling:'), findsOneWidget);
      expect(find.text('720p (HD)'), findsOneWidget);
      expect(find.byKey(const Key('embed_subtitles_toggle')), findsOneWidget);
      expect(find.text('Clip / Trim Range'), findsOneWidget);

      // Verify 720p format was selected due to quality ceiling
      expect(find.textContaining('Selected: 136'), findsOneWidget);

      // Tap Download Now and verify config forwarding
      final downloadBtn = find.widgetWithText(ElevatedButton, 'Download Now');
      await tester.tap(downloadBtn);
      await tester.pumpAndSettle();

      expect(mockEngine.lastStartDownloadConfig, isNotNull);
      expect(mockEngine.lastStartDownloadConfig!['quality_ceiling'], '720p');
      expect(mockEngine.lastStartDownloadConfig!['embed_subtitles'], isTrue);
      expect(mockEngine.lastStartDownloadConfig!['download_subtitles'], isTrue);
    });

    testWidgets(
      'audio-only mode disables embed subtitles and hides quality ceiling',
      (tester) async {
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final prefs = await _prefs();
        final mockEngine = _ToggleTestMockEngine();

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(prefs),
              engineProvider.overrideWithValue(mockEngine),
            ],
            child: const MaterialApp(
              home: FormatPickerScreen(
                url: 'https://www.youtube.com/watch?v=inline_toggles2',
                title: 'Toggles Test 2',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Switch to Audio Only
        await tester.tap(find.text('Audio Only'));
        await tester.pumpAndSettle();

        // Quality Ceiling should be hidden
        expect(find.text('Quality Ceiling:'), findsNothing);

        // Embed Subtitles should be disabled with explanation
        expect(find.text('Requires video stream'), findsOneWidget);
        final subtitleSwitch = tester.widget<SwitchListTile>(
          find.byKey(const Key('embed_subtitles_toggle')),
        );
        expect(subtitleSwitch.onChanged, isNull);
        expect(subtitleSwitch.value, isFalse);

        // Download Now in audio mode should NOT include embed_subtitles
        final downloadBtn = find.widgetWithText(ElevatedButton, 'Download Now');
        await tester.tap(downloadBtn);
        await tester.pumpAndSettle();

        expect(mockEngine.lastStartDownloadConfig!['audio_only'], isTrue);
        expect(mockEngine.lastStartDownloadConfig!['embed_subtitles'], isNull);
      },
    );

    testWidgets(
      'clip trim range validates input and generates download_sections',
      (tester) async {
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final prefs = await _prefs();
        final mockEngine = _ToggleTestMockEngine();

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(prefs),
              engineProvider.overrideWithValue(mockEngine),
            ],
            child: const MaterialApp(
              home: FormatPickerScreen(
                url: 'https://www.youtube.com/watch?v=inline_toggles3',
                title: 'Toggles Test 3',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Enable Clip / Trim Range
        final clipSwitch = find.byKey(const Key('clip_range_switch'));
        expect(clipSwitch, findsOneWidget);
        await tester.tap(clipSwitch);
        await tester.pumpAndSettle();

        // Since end time is empty, validation error should appear
        expect(find.text('Enter clip end time (e.g. 01:30)'), findsOneWidget);

        // Download button should be disabled
        final downloadBtn = tester.widget<ElevatedButton>(
          find.widgetWithText(ElevatedButton, 'Download Now'),
        );
        expect(downloadBtn.onPressed, isNull);

        // Enter start > end
        await tester.enterText(
          find.byKey(const Key('clip_start_field')),
          '02:00',
        );
        await tester.enterText(
          find.byKey(const Key('clip_end_field')),
          '01:00',
        );
        await tester.pumpAndSettle();

        expect(find.text('End time must be after start time'), findsOneWidget);
        expect(
          tester
              .widget<ElevatedButton>(
                find.widgetWithText(ElevatedButton, 'Download Now'),
              )
              .onPressed,
          isNull,
        );

        // Enter valid clip: start 00:30, end 02:15
        await tester.enterText(
          find.byKey(const Key('clip_start_field')),
          '00:30',
        );
        await tester.enterText(
          find.byKey(const Key('clip_end_field')),
          '02:15',
        );
        await tester.pumpAndSettle();

        // Validation error should be gone and Download Now button enabled
        expect(find.text('End time must be after start time'), findsNothing);
        expect(
          tester
              .widget<ElevatedButton>(
                find.widgetWithText(ElevatedButton, 'Download Now'),
              )
              .onPressed,
          isNotNull,
        );

        // Tap Download Now
        await tester.tap(find.widgetWithText(ElevatedButton, 'Download Now'));
        await tester.pumpAndSettle();

        // Verify download_sections has '*30-135' (00:30 -> 30s, 02:15 -> 135s)
        expect(mockEngine.lastStartDownloadConfig, isNotNull);
        expect(mockEngine.lastStartDownloadConfig!['download_sections'], [
          '*30-135',
        ]);
        expect(
          mockEngine.lastStartDownloadConfig!['force_keyframes_at_cuts'],
          isTrue,
        );

        // Verify session retained the clip values
        final session = PickerSessionState.instance;
        expect(session.clipEnabled, isTrue);
        expect(session.clipStart, '00:30');
        expect(session.clipEnd, '02:15');
      },
    );
  });
}
