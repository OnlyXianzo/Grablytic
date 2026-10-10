import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/engine/engine_provider.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/core/utils/notification_helper.dart';

class _NotificationEngine extends MockEngineService {
  Map<String, dynamic> permission = {'granted': false};
  Object? permissionError;
  bool failPost = false;
  int permissionChecks = 0;
  final events = <String>[];
  Completer<Map<String, dynamic>>? pendingPermission;

  @override
  Future<Map<String, dynamic>> notificationPermissionStatus() async {
    permissionChecks++;
    events.add('permission');
    if (permissionError != null) throw permissionError!;
    return pendingPermission == null
        ? permission
        : await pendingPermission!.future;
  }

  @override
  Future<void> showSuccessNotification({
    required String downloadId,
    required String title,
    required String message,
  }) async {
    events.add('success');
    if (failPost) throw StateError('post failed');
    await super.showSuccessNotification(
      downloadId: downloadId,
      title: title,
      message: message,
    );
  }

  @override
  Future<void> showErrorNotification({
    required String downloadId,
    required String title,
    required String error,
  }) async {
    events.add('error');
    if (failPost) throw StateError('post failed');
    await super.showErrorNotification(
      downloadId: downloadId,
      title: title,
      error: error,
    );
  }
}

void main() {
  late _NotificationEngine engine;
  late BuildContext context;
  late WidgetRef ref;

  setUp(() => engine = _NotificationEngine());
  tearDown(() => engine.dispose());

  Future<void> pumpHost(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [engineProvider.overrideWithValue(engine)],
        child: MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.indigo,
              brightness: brightness,
            ),
          ),
          home: Scaffold(
            body: Consumer(
              builder: (ctx, widgetRef, _) {
                context = ctx;
                ref = widgetRef;
                return const SizedBox();
              },
            ),
          ),
        ),
      ),
    );
  }

  for (final brightness in Brightness.values) {
    testWidgets('inline notification uses inverse colors in $brightness', (
      tester,
    ) async {
      await pumpHost(tester, brightness: brightness);
      await showAppNotification(context, ref, message: 'Saved');
      await tester.pumpAndSettle();
      final snack = tester.widget<SnackBar>(find.byType(SnackBar));
      final colors = Theme.of(context).colorScheme;
      expect(snack.backgroundColor, colors.inverseSurface);
      expect((snack.content as Text).style!.color, colors.onInverseSurface);
      expect(snack.behavior, SnackBarBehavior.floating);
      expect(snack.duration, const Duration(seconds: 3));
      expect(engine.permissionChecks, 0);
      expect(engine.successNotifications, isEmpty);
    });

    testWidgets('styledSnackBar preserves action and duration in $brightness', (
      tester,
    ) async {
      await pumpHost(tester, brightness: brightness);
      var presses = 0;
      final action = SnackBarAction(label: 'Undo', onPressed: () => presses++);
      final snack = styledSnackBar(
        context,
        'Removed',
        action: action,
        duration: const Duration(seconds: 7),
      );
      final colors = Theme.of(context).colorScheme;
      expect(snack.backgroundColor, colors.inverseSurface);
      expect((snack.content as Text).style!.color, colors.onInverseSurface);
      expect(snack.behavior, SnackBarBehavior.floating);
      expect(snack.shape, isA<RoundedRectangleBorder>());
      expect(snack.duration, const Duration(seconds: 7));
      expect(snack.action, same(action));
      ScaffoldMessenger.of(context).showSnackBar(snack);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Undo'));
      expect(presses, 1);
    });
  }

  testWidgets('granted permission posts one native success after checking', (
    tester,
  ) async {
    engine.permission = {'granted': true};
    await pumpHost(tester);
    await showAppNotification(
      context,
      ref,
      title: 'Complete',
      message: 'Video saved',
    );
    await tester.pumpAndSettle();
    expect(engine.events, ['permission', 'success']);
    expect(engine.successNotifications.single, {
      'download_id': startsWith('app_'),
      'title': 'Complete',
      'message': 'Video saved',
    });
    expect(engine.errorNotifications, isEmpty);
    expect(find.byType(SnackBar), findsNothing);
  });

  for (final title in [null, 'Failed']) {
    testWidgets('error notification uses title ${title ?? 'Notice'}', (
      tester,
    ) async {
      engine.permission = {'granted': true};
      await pumpHost(tester);
      await showAppNotification(
        context,
        ref,
        title: title,
        message: 'Try again',
        isError: true,
      );
      await tester.pumpAndSettle();
      expect(engine.events, ['permission', 'error']);
      expect(engine.errorNotifications.single['title'], title ?? 'Notice');
      expect(engine.errorNotifications.single['error'], 'Try again');
      expect(engine.successNotifications, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
    });
  }

  for (final permission in <Map<String, dynamic>>[
    {'granted': false},
    {},
    {'granted': 'true'},
  ]) {
    testWidgets('permission $permission falls back without native posting', (
      tester,
    ) async {
      engine.permission = permission;
      await pumpHost(tester);
      var presses = 0;
      await showAppNotification(
        context,
        ref,
        title: 'Saved',
        message: 'Open file',
        duration: const Duration(seconds: 8),
        action: SnackBarAction(label: 'Open', onPressed: () => presses++),
      );
      await tester.pumpAndSettle();
      expect(engine.events, ['permission']);
      expect(find.text('Open file'), findsOneWidget);
      expect(
        tester.widget<SnackBar>(find.byType(SnackBar)).duration,
        const Duration(seconds: 8),
      );
      await tester.tap(find.text('Open'));
      expect(presses, 1);
    });
  }

  for (final failure in ['permission', 'success', 'error']) {
    testWidgets('$failure failure falls back to one visible notification', (
      tester,
    ) async {
      engine.permission = {'granted': true};
      engine.permissionError = failure == 'permission'
          ? StateError('unavailable')
          : null;
      engine.failPost = failure != 'permission';
      await pumpHost(tester);
      await showAppNotification(
        context,
        ref,
        title: 'Notice',
        message: 'Still visible',
        isError: failure == 'error',
      );
      await tester.pumpAndSettle();
      expect(find.text('Still visible'), findsOneWidget);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('unmounting during permission lookup does not show a snackbar', (
    tester,
  ) async {
    engine.pendingPermission = Completer<Map<String, dynamic>>();
    await pumpHost(tester);
    final notification = showAppNotification(
      context,
      ref,
      title: 'Saved',
      message: 'Too late',
    );
    await tester.pumpWidget(const SizedBox());
    engine.pendingPermission!.complete({'granted': false});
    await notification;
    await tester.pump();
    expect(engine.events, ['permission']);
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
