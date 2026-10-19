import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/database/download_history_db.dart';
import 'package:grablytic/core/engine/engine_contract.dart';
import 'package:grablytic/core/engine/platform_channel_engine_service.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Android MethodChannel reaches Chaquopy and returns the Python contract',
    (tester) async {
      final root = await Directory.systemTemp.createTemp(
        'grablytic-engine-ipc-',
      );
      addTearDown(() async {
        try {
          await root.delete(recursive: true);
        } catch (_) {}
      });

      final engine = PlatformChannelEngineService();
      addTearDown(engine.dispose);

      await engine.setPaths({
        'data_dir': '${root.path}/data',
        'output_dir': '${root.path}/output',
        'cache_dir': '${root.path}/cache',
        'ffmpeg_path': null,
        'cookies_path': null,
        'aria2c_path': null,
        'deno_path': null,
        'po_token': null,
      });

      final bootstrap = await engine.bootstrap().timeout(
        const Duration(seconds: 45),
      );
      expect(bootstrap['success'], isTrue);
      expect(bootstrap['contract_version'], EngineContract.version);
      expect(
        bootstrap['contract_version_string'],
        EngineContract.versionString,
      );

      final queue = await engine.queueStatus().timeout(
        const Duration(seconds: 15),
      );
      expect(queue['success'], isTrue);
      expect(queue['active'], isA<List<dynamic>>());
      expect(queue['queued'], isA<List<dynamic>>());

      final history = DownloadHistoryDb.instance;
      final historyId = 'android-fts-${DateTime.now().millisecondsSinceEpoch}';
      addTearDown(() async {
        try {
          await history.delete(historyId);
        } catch (_) {}
        await history.closeForTesting();
      });
      await history.insert(
        DownloadRecord(
          id: historyId,
          url: 'https://example.test/$historyId',
          title: 'Android system SQLite FTS verification',
        ),
      );
      expect(history.fts4EnabledForTesting, isTrue);
      expect(
        (await history.getAll(search: 'SQLite')).any((r) => r.id == historyId),
        isTrue,
      );
    },
  );
}
