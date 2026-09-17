import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/engine/desktop_engine_service.dart';
import 'package:grablytic/core/engine/engine_codec.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('desktop IPC head-of-line blocking [item-3]', () {
    test('slow extractions get a longer timeout than cancel/queue-status', () {
      // Slow network extractions must not false-timeout at the 30s fast
      // budget while a prompt cancel sits behind them (desync). Cancel and
      // queue-status stay on the tight budget; formats/playlist/search get
      // headroom.
      final slowFormats =
          requestTimeoutForMethod(EngineMethods.getFormats);
      final slowPlaylist =
          requestTimeoutForMethod(EngineMethods.playlistInfo);
      final slowSearch =
          requestTimeoutForMethod(EngineMethods.searchQuery);
      final fastCancel =
          requestTimeoutForMethod(EngineMethods.cancelDownload);
      final fastQueue =
          requestTimeoutForMethod(EngineMethods.queueStatus);

      expect(slowFormats, greaterThan(fastCancel),
          reason: 'formats/get must outlive the cancel budget');
      expect(slowPlaylist, greaterThan(fastQueue),
          reason: 'playlist/info must outlive the queue-status budget');
      expect(slowSearch, greaterThan(fastCancel),
          reason: 'search/query must outlive the cancel budget');
      expect(fastCancel, const Duration(seconds: 30));
      expect(fastQueue, const Duration(seconds: 30));
    });

    test('cancel and queue-status take the fast lane past queued writes', () {
      // Cancel/queue-status must bypass the serialized stdin write queue so
      // one slow formats/playlist extraction cannot hold them hostage.
      expect(isFastLaneMethod(EngineMethods.cancelDownload), isTrue);
      expect(isFastLaneMethod(EngineMethods.queueStatus), isTrue);
      expect(isFastLaneMethod(EngineMethods.getFormats), isFalse);
      expect(isFastLaneMethod(EngineMethods.playlistInfo), isFalse);
    });
  });
}
