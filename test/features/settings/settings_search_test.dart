import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/features/home/screens/link_saver_screen.dart';
import 'package:grablytic/features/settings/screens/settings_screen.dart';
import 'package:grablytic/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<void> pumpSettings(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'downloadPath': '/downloads/MyClips',
    });
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final entry in {
    '  nEtWoRk  ': 'Network and speed',
    'PROXY': 'Network and speed',
    'myclips': 'Storage',
    'offline': 'Link Saver',
  }.entries) {
    testWidgets('search matches title/subtitle: ${entry.key}', (tester) async {
      await pumpSettings(tester);
      await tester.enterText(find.byType(TextField), entry.key);
      await tester.pumpAndSettle();
      expect(find.text(entry.value), findsOneWidget);
      expect(find.text('General'), findsNothing);
      expect(find.text('Appearance'), findsNothing);
    });
  }

  testWidgets('clearing a no-match search restores categories', (tester) async {
    await pumpSettings(tester);
    await tester.enterText(find.byType(TextField), 'no-such-setting');
    await tester.pumpAndSettle();
    expect(find.text('Downloads'), findsNothing);
    expect(find.text('App'), findsNothing);
    await tester.tap(find.byIcon(Icons.clear));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(find.text('General'), findsOneWidget);
    expect(find.text('Link Saver'), findsOneWidget);
  });

  testWidgets('filtered Link Saver result opens saved links screen', (
    tester,
  ) async {
    await pumpSettings(tester);
    await tester.enterText(find.byType(TextField), 'offline');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Link Saver'));
    await tester.pumpAndSettle();
    expect(find.byType(LinkSaverScreen), findsOneWidget);
    expect(find.text('No saved links'), findsOneWidget);
  });
}
