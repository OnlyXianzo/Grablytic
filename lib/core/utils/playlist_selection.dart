/// Playlist-selection helpers (03-B UI wiring).
///
/// Dart mirror of `engine/grablytic_engine/playlist.py`:
/// - [isPlaylistUrl] mirrors `detect_playlist` (same match set, so the UI
///   routes exactly the URLs the engine treats as playlists).
/// - [buildPlaylistItemsString] mirrors `build_playlist_items`: the values
///   are the 1-based `index` numbers reported by `get_playlist_info`
///   (yt-dlp `playlist_items` syntax is 1-indexed — no 0→1 adjustment).
///   Duplicates are dropped, order is kept, empty input yields `""`,
///   anything that is not a positive int (or digit-string) throws
///   [ArgumentError] instead of silently downloading the wrong entries.
final List<RegExp> _playlistPatterns = [
  RegExp(r'list='),
  RegExp(r'/playlist'),
  RegExp(r'/sets/'),
  RegExp(r'playlist\?'),
  RegExp(r'channel/'),
  RegExp(r'/c/'),
  RegExp(r'/@'),
  RegExp(r'user/'),
];

bool isPlaylistUrl(String url) {
  return _playlistPatterns.any((p) => p.hasMatch(url));
}

/// Translate user-selected playlist entry indices into a yt-dlp
/// `playlist_items` string. Exact parity with engine `build_playlist_items`:
/// duplicates are dropped but order is kept, so callers pass indices in
/// ascending playlist order and let the engine apply `playlist_rev` /
/// `playlist_rand` afterwards (yt-dlp selects by index first, then
/// reverses/shuffles the selected set — verified against installed
/// `YoutubeDL.py` — so the UI must NOT pre-reverse the string).
String buildPlaylistItemsString(List<dynamic> selected) {
  final seen = <int>[];
  for (final raw in selected) {
    final int idx;
    if (raw is int) {
      idx = raw;
    } else if (raw is String && raw.trim().isNotEmpty &&
        RegExp(r'^\d+$').hasMatch(raw.trim())) {
      idx = int.parse(raw.trim());
    } else {
      throw ArgumentError('Invalid playlist index: $raw');
    }
    if (idx < 1) {
      throw ArgumentError('Invalid playlist index (1-based): $raw');
    }
    if (!seen.contains(idx)) seen.add(idx);
  }
  return seen.join(',');
}
