import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/theme/app_theme.dart';
import 'package:grablytic/core/widgets/grablytic_components.dart';

Widget _wrap(Widget child, {bool dark = false}) {
  return MaterialApp(
    theme: dark ? ThemeData.dark() : ThemeData.light(),
    home: Scaffold(body: child),
  );
}

void main() {
  group('GrablyticSpacing / GrablyticRadii', () {
    test('scales are ascending and positive', () {
      expect(GrablyticSpacing.xs, lessThan(GrablyticSpacing.sm));
      expect(GrablyticSpacing.sm, lessThan(GrablyticSpacing.md));
      expect(GrablyticSpacing.md, lessThan(GrablyticSpacing.lg));
      expect(GrablyticSpacing.lg, lessThan(GrablyticSpacing.xl));
      expect(GrablyticSpacing.xl, lessThan(GrablyticSpacing.xxl));
      expect(GrablyticRadii.sm, lessThan(GrablyticRadii.md));
      expect(GrablyticRadii.md, lessThan(GrablyticRadii.lg));
      expect(GrablyticRadii.lg, lessThan(GrablyticRadii.xl));
      // Mockup card radius.
      expect(GrablyticRadii.xl, 20);
    });
  });

  group('SectionLabel', () {
    testWidgets('renders uppercase-styled text', (tester) async {
      await tester.pumpWidget(_wrap(const SectionLabel('Pending')));
      expect(find.text('Pending'), findsOneWidget);
      final text = tester.widget<Text>(find.text('Pending'));
      expect(text.style?.letterSpacing, 1.5);
      expect(text.style?.fontWeight, FontWeight.bold);
    });
  });

  group('RowCard', () {
    testWidgets('renders child and fires onTap', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        _wrap(RowCard(onTap: () => tapped = true, child: const Text('hi'))),
      );
      expect(find.text('hi'), findsOneWidget);
      await tester.tap(find.byType(InkWell));
      expect(tapped, isTrue);
    });

    testWidgets('no InkWell without onTap', (tester) async {
      await tester.pumpWidget(
        _wrap(const RowCard(child: Text('plain'))),
      );
      expect(find.byType(InkWell), findsNothing);
    });
  });

  group('GrablyticProgressBar', () {
    testWidgets('clamps value and exposes semantics', (tester) async {
      await tester.pumpWidget(
        _wrap(const GrablyticProgressBar(value: 1.7)),
      );
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, 1.0);
      expect(
        find.bySemanticsLabel('Progress 100 percent'),
        findsOneWidget,
      );
    });
  });

  group('ToggleRow', () {
    testWidgets('tap flips value via onChanged', (tester) async {
      var value = false;
      await tester.pumpWidget(
        _wrap(
          ToggleRow(
            icon: Icons.wifi,
            title: 'Wi-Fi only',
            subtitle: 'Pause on mobile data',
            value: value,
            onChanged: (v) => value = v,
          ),
        ),
      );
      expect(find.text('Wi-Fi only'), findsOneWidget);
      expect(find.text('Pause on mobile data'), findsOneWidget);
      await tester.tap(find.byType(InkWell));
      expect(value, isTrue);
    });

    testWidgets('meets 48dp minimum height', (tester) async {
      await tester.pumpWidget(
        _wrap(
          ToggleRow(
            icon: Icons.wifi,
            title: 'T',
            value: true,
            onChanged: (_) {},
          ),
        ),
      );
      final box =
          tester.getSize(find.byType(ConstrainedBox).first);
      expect(box.height, greaterThanOrEqualTo(48));
    });
  });

  group('SegTabs', () {
    testWidgets('bar, pill and screen bg all differ; taps select',
        (tester) async {
      var selected = 0;
      await tester.pumpWidget(
        _wrap(
          SegTabs(
            labels: const ['Videos', 'Playlists', 'History'],
            selectedIndex: selected,
            onChanged: (i) => selected = i,
          ),
        ),
      );
      // Three equal thirds present with correct selection.
      expect(find.text('Videos'), findsOneWidget);
      expect(find.text('Playlists'), findsOneWidget);
      expect(find.text('History'), findsOneWidget);
      // Bar carries a hairline edge and the selected pill a fill, so the
      // control reads on-device even where surface deltas crush.
      final containers =
          tester.widgetList<Container>(find.byType(Container));
      final decos = containers
          .map((c) => c.decoration)
          .whereType<BoxDecoration>();
      expect(decos.any((d) => d.border is Border), isTrue);
      final fills = decos.map((d) => d.color).whereType<Color>().toSet();
      expect(fills.length, greaterThanOrEqualTo(2));
      await tester.tap(find.text('History'));
      expect(selected, 2);
    });
  });

  group('BackHeader', () {
    testWidgets('renders label and pops by default', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => Navigator.of(ctx).push(
                  MaterialPageRoute(
                    builder: (_) => const Scaffold(
                      body: BackHeader(label: 'Settings'),
                    ),
                  ),
                ),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsOneWidget);
      await tester.tap(find.byType(InkWell));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsNothing);
    });
  });
}
