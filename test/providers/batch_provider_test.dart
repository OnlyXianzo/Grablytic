import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grablytic/core/engine/engine_provider.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/providers/batch_provider.dart';
import 'package:grablytic/providers/preset_provider.dart';
import 'package:grablytic/providers/settings_provider.dart';

class _RecordingEngine extends MockEngineService {
  final List<Map<String, dynamic>> configs = [];

  @override
  Future<Map<String, dynamic>> startDownload({
    required String url,
    required String downloadId,
    required Map<String, dynamic> config,
    required String networkType,
  }) async {
    configs.add(Map<String, dynamic>.from(config));
    return {'success': true};
  }
}

Future<ProviderContainer> _container(_RecordingEngine engine) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      engineProvider.overrideWithValue(engine),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

BatchItem _item(String id) =>
    BatchItem(url: 'https://instagram.com/p/$id/', title: 'reel $id');

void main() {
  test('batch snapshot ceiling fans out to every item', () async {
    final engine = _RecordingEngine();
    final container = await _container(engine);

    container.read(batchProvider.notifier).startBatch(
      [_item('A'), _item('B')],
      qualityCeiling: '480p',
    );
    await Future.delayed(const Duration(milliseconds: 100));

    expect(engine.configs, hasLength(2));
    expect(
      engine.configs.map((c) => c['quality_ceiling']),
      ['480p', '480p'],
    );
  });

  test('mid-queue preset change cannot split a snapshotted batch', () async {
    final engine = _RecordingEngine();
    final container = await _container(engine);

    container.read(batchProvider.notifier).startBatch(
      [_item('A'), _item('B')],
      qualityCeiling: '480p',
    );
    // User flips the global preset while the batch is running.
    container.read(presetsProvider.notifier).setActivePreset('preset_720p');
    await Future.delayed(const Duration(milliseconds: 100));

    expect(engine.configs, hasLength(2));
    expect(
      engine.configs.map((c) => c['quality_ceiling']),
      ['480p', '480p'],
    );
  });

  test('null snapshot follows the live active preset', () async {
    final engine = _RecordingEngine();
    final container = await _container(engine);

    // Default active preset is preset_1080p.
    container.read(batchProvider.notifier).startBatch([_item('A')]);
    await Future.delayed(const Duration(milliseconds: 100));

    expect(engine.configs, hasLength(1));
    expect(engine.configs.single['quality_ceiling'], '1080p');
    expect(container.read(batchProvider).qualityCeiling, isNull);
  });
}
