import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grablytic/core/engine/engine_provider.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/features/home/screens/format_picker_screen.dart';
import 'package:grablytic/providers/resume_provider.dart';
import 'package:grablytic/providers/settings_provider.dart';

class _BlockingEngine extends MockEngineService {
  final Completer<Map<String, dynamic>> gate = Completer();

  @override
  Future<Map<String, dynamic>> getFormats({
    required String url,
    required Map<String, dynamic> config,
  }) =>
      gate.future;
}

class _NoopResume extends ResumeNotifier {
  _NoopResume(super.ref);
  @override
  Future<void> scan() async {
    state = const AsyncValue.data([]);
  }
}

void main() {
  group('FormatPicker loading state (never black)', () {
    testWidgets('spinner + status + cancel while fetching', (tester) async {
      SharedPreferences.setMockInitialValues({'onboardingCompleted': true});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWithValue(_BlockingEngine()),
            resumeProvider.overrideWith((ref) => _NoopResume(ref)),
          ],
          child: MaterialApp(
            home: Builder(
              // Picker is pushed in production; Cancel must pop back here.
              builder: (ctx) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(ctx).push(
                      MaterialPageRoute(
                        builder: (_) => const FormatPickerScreen(
                          url: 'https://example.com/v',
                          title: 'V',
                        ),
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('picker_loading')), findsOneWidget);
      expect(find.text('Fetching formats…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      final cancelBtn = find.descendant(
        of: find.byKey(const Key('picker_loading')),
        matching: find.text('Cancel'),
      );
      expect(cancelBtn, findsOneWidget);
      await tester.tap(cancelBtn);
      // Shimmer dies with the picker, so settling is safe here.
      await tester.pumpAndSettle();
      expect(find.byType(FormatPickerScreen), findsNothing);
    });
  });
}
