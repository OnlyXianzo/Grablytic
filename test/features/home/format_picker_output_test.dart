import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/engine/engine_provider.dart';
import 'package:grablytic/core/engine/extraction_cache.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/core/utils/picker_session_state.dart';
import 'package:grablytic/features/home/screens/format_picker_screen.dart';
import 'package:grablytic/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _OutputEngine extends MockEngineService {
  final configs = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> startDownload({
    required String url,
    required String downloadId,
    required Map<String, dynamic> config,
    required String networkType,
  }) async {
    configs.add(Map.of(config));
    // Keep the picker open; no real downloads or progress timers.
    return {'success': false};
  }
}

void main() {
  late _OutputEngine engine;
  final session = PickerSessionState.instance;
  final filename = find.byKey(const Key('custom_filename_field'));
  final download = find.widgetWithText(ElevatedButton, 'Download Now');

  setUp(() {
    session.reset();
    ExtractionCache.instance.clear();
    engine = _OutputEngine();
  });
  tearDown(() {
    session.reset();
    ExtractionCache.instance.clear();
    engine.dispose();
  });

  Future<void> pumpPicker(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'saveDescription': false,
      'saveThumbnails': true,
    });
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          engineProvider.overrideWithValue(engine),
        ],
        child: const MaterialApp(
          home: FormatPickerScreen(
            url: 'https://example.com/video',
            title: 'Video',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('reset clears all newly added picker session overrides', () {
    session.saveDescription = true;
    session.saveThumbnails = false;
    session.customFileName = 'custom.%(ext)s';
    session.fileNameTemplate = '%(title)s.%(ext)s';
    expect(PickerSessionState.instance.saveDescription, isTrue);
    expect(PickerSessionState.instance.saveThumbnails, isFalse);
    expect(PickerSessionState.instance.customFileName, 'custom.%(ext)s');
    expect(PickerSessionState.instance.fileNameTemplate, '%(title)s.%(ext)s');
    session.reset();
    expect(session.saveDescription, isNull);
    expect(session.saveThumbnails, isNull);
    expect(session.customFileName, isNull);
    expect(session.fileNameTemplate, isNull);
  });

  testWidgets(
    'metadata defaults can be overridden and forwarded to the engine',
    (tester) async {
      await pumpPicker(tester);
      final description = find.byKey(const Key('save_description_toggle'));
      final thumbnail = find.byKey(const Key('save_thumbnail_toggle'));
      expect(tester.widget<SwitchListTile>(description).value, isFalse);
      expect(tester.widget<SwitchListTile>(thumbnail).value, isTrue);
      await tester.ensureVisible(description);
      await tester.tap(description);
      await tester.ensureVisible(thumbnail);
      await tester.tap(thumbnail);
      await tester.pumpAndSettle();
      expect(session.saveDescription, isTrue);
      expect(session.saveThumbnails, isFalse);
      await tester.ensureVisible(download);
      await tester.tap(download);
      await tester.pumpAndSettle();
      expect(engine.configs.single['write_description'], isTrue);
      expect(engine.configs.single['embedthumbnail'], isFalse);
    },
  );

  testWidgets('saved session overrides take precedence over global settings', (
    tester,
  ) async {
    session.saveDescription = true;
    session.saveThumbnails = false;
    session.customFileName = 'session.%(ext)s';
    await pumpPicker(tester);
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const Key('save_description_toggle')),
          )
          .value,
      isTrue,
    );
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const Key('save_thumbnail_toggle')),
          )
          .value,
      isFalse,
    );
    expect(
      tester.widget<TextField>(filename).controller!.text,
      'session.%(ext)s',
    );
  });

  final unsafeNames = [
    '../escape',
    r'folder\..\escape',
    '/absolute',
    r'C:\absolute',
    '~/home',
    'nul\x00byte',
    'x' * 257,
  ];
  for (var i = 0; i < unsafeNames.length; i++) {
    testWidgets(
      'unsafe filename case $i disables download and recovers after clearing',
      (tester) async {
        await pumpPicker(tester);
        await tester.enterText(filename, unsafeNames[i]);
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(filename).decoration!.errorText,
          contains('Unsafe template'),
        );
        expect(tester.widget<ElevatedButton>(download).onPressed, isNull);
        expect(engine.configs, isEmpty);
        await tester.enterText(filename, '');
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(filename).decoration!.errorText,
          isNull,
        );
        expect(tester.widget<ElevatedButton>(download).onPressed, isNotNull);
      },
    );
  }

  for (final custom in [
    'x' * 256,
    'series/%(title)s.%(ext)s',
    '  custom.%(ext)s  ',
    '',
  ]) {
    testWidgets(
      'safe filename of length ${custom.length} respects custom/template precedence',
      (tester) async {
        session.fileNameTemplate = '%(title)s.%(ext)s';
        session.customFileName = 'previous.%(ext)s';
        await pumpPicker(tester);
        await tester.enterText(filename, custom);
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(filename).decoration!.errorText,
          isNull,
        );
        expect(session.customFileName, custom);
        await tester.ensureVisible(download);
        await tester.tap(download);
        await tester.pumpAndSettle();
        expect(
          engine.configs.single['output_tmpl'],
          custom.trim().isEmpty ? '%(title)s.%(ext)s' : custom.trim(),
        );
      },
    );
  }
}
