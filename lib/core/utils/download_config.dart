import '../../providers/settings_provider.dart';

/// Shared engine-config overlay built from user settings (P1).
///
/// Keys match `engine/truestream_engine/config.py` DEFAULT_CFG exactly
/// (Dart `downloadSubtitles` → yt-dlp `writesubtitles`, etc.). Null/empty
/// values are omitted so engine defaults survive the
/// `{**DEFAULT_CFG, **config}` merge in `build_ydl_opts()`.
/// Only keys with a real user setting on the Dart side are sent —
/// thumbnail/metadata have no toggles (engine defaults already on).
Map<String, dynamic> settingsDownloadConfig(AppSettings settings) {
  final config = <String, dynamic>{
    'writesubtitles': settings.downloadSubtitles,
    'writeautomaticsub': settings.downloadAutoSubtitles,
    'subtitleslangs': List<String>.from(settings.subtitleLanguages),
    'embedsubtitles': settings.embedSubtitles,
    'sponsorblock_cats': List<String>.from(settings.sponsorBlockCats),
    'aria2c_enabled': settings.aria2cEnabled,
    'aria2c_chunks': settings.aria2cChunks,
    'split_chapters': settings.splitChapters,
    'write_description': settings.saveDescription,
  };
  final maxSpeed = settings.aria2cMaxSpeed;
  if (maxSpeed != null && maxSpeed.trim().isNotEmpty) {
    config['aria2c_max_speed'] = maxSpeed.trim();
  }
  final proxy = settings.proxy;
  if (proxy != null && proxy.trim().isNotEmpty) {
    config['proxy'] = proxy.trim();
  }
  return config;
}
