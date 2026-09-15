import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/engine/engine_codec.dart';

void main() {
  group('EngineMethods (BRUTAL-1 single source)', () {
    test('RED: every contract method has a non-empty unique id', () {
      final ids = <String>{
        EngineMethods.bootstrap,
        EngineMethods.setPaths,
        EngineMethods.startDownload,
        EngineMethods.cancelDownload,
        EngineMethods.queueStatus,
        EngineMethods.setConcurrency,
        EngineMethods.clearArchive,
        EngineMethods.getFormats,
        EngineMethods.playlistInfo,
        EngineMethods.searchQuery,
        EngineMethods.getSharedUrl,
        EngineMethods.sharedUrlInbound,
        EngineMethods.scanResume,
        EngineMethods.exportLog,
        EngineMethods.updateCheck,
        EngineMethods.setUpdateChannel,
        EngineMethods.batteryStatus,
        EngineMethods.batteryRequest,
        EngineMethods.notificationStatus,
        EngineMethods.notificationRequest,
        EngineMethods.notificationSettings,
        EngineMethods.openUrl,
        EngineMethods.syncSchedule,
      };
      expect(ids, hasLength(23));
      expect(ids.every((id) => id.isNotEmpty), isTrue);
    });

    test('RED: wire values match the native/python dispatch table', () {
      // These strings are the cross-layer contract (Kotlin MainActivity +
      // Python __main__.py dispatch on these exact values). Renaming here
      // without renaming there breaks the boundary silently.
      expect(EngineMethods.startDownload, 'download/start');
      expect(EngineMethods.cancelDownload, 'download/cancel');
      expect(EngineMethods.scanResume, 'resume/scan');
      expect(EngineMethods.bootstrap, 'engine/bootstrap');
      expect(EngineMethods.updateCheck, 'engine/update_check');
      expect(EngineMethods.setPaths, 'paths/set');
      expect(EngineMethods.getSharedUrl, 'intent/get_shared');
      expect(EngineMethods.sharedUrlInbound, 'intent/shared_url');
      expect(EngineMethods.openUrl, 'intent/open_url');
      expect(EngineMethods.syncSchedule, 'schedule/sync');
    });
  });

  group('EngineEnvelope', () {
    test('RED: decodeResponse maps null to empty', () {
      expect(EngineEnvelope.decodeResponse(null), isEmpty);
    });

    test('RED: decodeResponse parses a JSON object string', () {
      final out = EngineEnvelope.decodeResponse(
          jsonEncode({'success': true, 'max_concurrent': 2}));
      expect(out['success'], isTrue);
      expect(out['max_concurrent'], 2);
    });

    test('RED: decodeResponse maps garbage to empty, never throws', () {
      expect(EngineEnvelope.decodeResponse('not-json{{{'), isEmpty);
      expect(EngineEnvelope.decodeResponse('[1,2]'), isEmpty);
      expect(EngineEnvelope.decodeResponse(''), isEmpty);
    });

    test('RED: encodeRequest builds the stdio envelope shape', () {
      final raw = EngineEnvelope.encodeRequest(
          id: 'abc', method: EngineMethods.startDownload, params: {'a': 1});
      final back = jsonDecode(raw) as Map<String, dynamic>;
      expect(back['id'], 'abc');
      expect(back['method'], 'download/start');
      expect(back['params'], {'a': 1});
    });

    test('RED: error builds the standard failure envelope', () {
      final out = EngineEnvelope.error(
          errorType: 'ERROR_X', message: 'nope', extra: {'k': 1});
      expect(out['success'], isFalse);
      expect(out['error_type'], 'ERROR_X');
      expect(out['error_message'], 'nope');
      expect(out['k'], 1);
    });
  });
}
