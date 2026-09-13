import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truestream/features/home/widgets/download_sparkline.dart';

void main() {
  testWidgets('renders empty samples without crashing', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: DownloadSparkline(samples: [])),
    ));
    expect(find.byType(DownloadSparkline), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(DownloadSparkline),
        matching: find.byType(CustomPaint),
      ),
      findsOneWidget,
    );
  });

  testWidgets('renders single sample without crashing', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: DownloadSparkline(samples: [1048576.0], height: 28),
      ),
    ));
    expect(find.byType(DownloadSparkline), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(DownloadSparkline),
        matching: find.byType(CustomPaint),
      ),
      findsOneWidget,
    );
  });

  testWidgets('renders multi-sample history', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: DownloadSparkline(
          samples: [1000, 2000, 1500, 3000, 2500],
          height: 28,
        ),
      ),
    ));
    expect(find.byType(DownloadSparkline), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(DownloadSparkline),
        matching: find.byType(CustomPaint),
      ),
      findsOneWidget,
    );
  });

  testWidgets('custom color propagates to painter', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: DownloadSparkline(
          samples: [1000, 2000],
          color: Colors.red,
          height: 28,
        ),
      ),
    ));
    final sparkline =
        tester.widget<DownloadSparkline>(find.byType(DownloadSparkline));
    expect(sparkline.color, Colors.red);
    expect(
      find.descendant(
        of: find.byType(DownloadSparkline),
        matching: find.byType(CustomPaint),
      ),
      findsOneWidget,
    );
  });

  testWidgets('renders inside Column without layout error', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            DownloadSparkline(
              samples: [100.0, 200.0, 300.0],
              height: 28,
            ),
          ],
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(find.byType(DownloadSparkline), findsOneWidget);
  });
}