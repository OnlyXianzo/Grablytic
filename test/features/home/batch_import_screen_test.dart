import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grablytic/core/engine/engine_provider.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/features/home/screens/batch_download_screen.dart';
import 'package:grablytic/features/home/screens/batch_import_screen.dart';
import 'package:grablytic/providers/settings_provider.dart';

void main() {
  testWidgets('paste -> count -> Start navigates to BatchDownloadScreen',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          engineProvider.overrideWithValue(MockEngineService()),
        ],
        child: const MaterialApp(home: BatchImportScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // Start disabled with no input.
    expect(find.byKey(const Key('batchImportCount')), findsOneWidget);
    expect(find.text('No links found yet'), findsOneWidget);
    final startBtn = find.byKey(const Key('batchImportStart'));
    expect(tester.widget<FilledButton>(startBtn).onPressed, isNull);

    await tester.enterText(
      find.byKey(const Key('batchImportInput')),
      'https://www.instagram.com/p/ABC123xyz_0/\n'
      'https://www.instagram.com/reel/DEF456uvw_1/\n',
    );
    await tester.pump();

    expect(find.text('2 links ready'), findsOneWidget);
    expect(tester.widget<FilledButton>(startBtn).onPressed, isNotNull);

    await tester.tap(startBtn);
    await tester.pumpAndSettle();

    expect(find.byType(BatchDownloadScreen), findsOneWidget);
  });
}
