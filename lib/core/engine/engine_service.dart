abstract class EngineService {
  Future<Map<String, dynamic>> bootstrap();
  Future<void> setPaths(Map<String, dynamic> paths);
  Future<Map<String, dynamic>> startDownload({
    required String url,
    required String downloadId,
    required Map<String, dynamic> config,
    required String networkType,
  });
  Future<Map<String, dynamic>> cancelDownload(String downloadId);
  Stream<Map<String, dynamic>> get progressStream;
  Future<Map<String, dynamic>> getFormats({
    required String url,
    required Map<String, dynamic> config,
  });
  Future<Map<String, dynamic>> getPlaylistInfo({
    required String url,
    required Map<String, dynamic> config,
  });
  Future<String?> getSharedUrl();
  Stream<String> get sharedUrlStream;
  Future<Map<String, dynamic>> scanResumeCandidates({required String cacheDir});
  Future<Map<String, dynamic>> updateCheck();
  Future<Map<String, dynamic>> setUpdateChannel(String channel);
  Stream<Map<String, dynamic>> get logStream;
}
