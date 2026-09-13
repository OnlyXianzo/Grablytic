import '../../providers/settings_provider.dart';
import 'playlist_selection.dart';

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
    'organize_by_folder': settings.archiveByFolder,
    'use_archive': settings.downloadArchive,
    'thumbnail_format': settings.pngThumbnails ? 'png' : 'jpg',
    // UI-level only (engine opts_builder ignores unknown keys): lets the
    // native layer gate completion/error alerts without a second IPC.
    'completion_alerts': settings.completionAlerts,
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

/// Playlist-entry config overlay (03-B UI wiring). Keys match
/// `engine/truestream_engine/config.py` (`playlist_items` /
/// `playlist_rev` / `playlist_rand`) and flow through `opts_builder.py`
/// into yt-dlp (`playlist_items` / `playlistreverse` / `playlistrandom`).
/// [selectedIndices] are the 1-based `index` values from `getPlaylistInfo`,
/// passed in ascending playlist order — reverse/shuffle travel as flags,
/// never as a reordered string (see [buildPlaylistItemsString]).
/// Merged OVER [settingsDownloadConfig] at the call site; `use_archive`
/// from settings still applies, so re-runs transparently skip completed
/// entries (no archive toggle needed in playlist UI).
Map<String, dynamic> playlistDownloadConfig({
  required List<dynamic> selectedIndices,
  bool reverse = false,
  bool shuffle = false,
}) {
  final config = <String, dynamic>{
    'playlist_items': buildPlaylistItemsString(selectedIndices),
  };
  if (reverse) config['playlist_rev'] = true;
  if (shuffle) config['playlist_rand'] = true;
  return config;
}
