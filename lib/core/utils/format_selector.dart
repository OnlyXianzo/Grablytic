/// Pure format pre-selection helpers (P0 fix).
///
/// Extracted from `FormatPickerScreen` so the preset auto-selection logic is
/// unit-testable without widgets. Rules (see Verified Approach 04):
/// - Video: filter `height <= ceiling` (fallback: full list), filter by
///   `preferredCodec` substring (fallback: unfiltered), sort desc by
///   (height, tbr/vbr, fps) and take first. Null-safe, empty-guarded.
/// - Audio: sort desc by (abr ?? tbr, tbr) and take first.
/// - Never trust yt-dlp input order (extractor `worst→best` vs sorter
///   re-ordering); codec filter runs BEFORE bitrate rank (cross-codec tbr
///   is incomparable); fps kept as tiebreak (never dropped).
library;

/// Map a preset ceiling/id to a target height (matches previous screen logic).
int targetHeightForCeiling(String qualityCeiling, String presetId) {
  if (qualityCeiling == '4k') return 2160;
  if (qualityCeiling == '1080p') return 1080;
  if (qualityCeiling == '720p') return 720;
  if (qualityCeiling == '480p' || presetId == 'preset_480p') return 480;
  return 99999;
}

num _num(Map<String, dynamic> f, String key) => (f[key] as num?) ?? 0;

int _compareVideoDesc(Map<String, dynamic> a, Map<String, dynamic> b) {
  final ha = _num(a, 'height');
  final hb = _num(b, 'height');
  if (ha != hb) return hb.compareTo(ha);
  final ta = (a['tbr'] as num?) ?? (a['vbr'] as num?) ?? 0;
  final tb = (b['tbr'] as num?) ?? (b['vbr'] as num?) ?? 0;
  if (ta != tb) return tb.compareTo(ta);
  final fa = _num(a, 'fps');
  final fb = _num(b, 'fps');
  if (fa != fb) return fb.compareTo(fa);
  return (a['format_id'] as String? ?? '').compareTo(b['format_id'] as String? ?? '');
}

/// Best video format id for [targetHeight] preferring [preferredCodec].
/// Returns [fallbackRecommendedId] (or null) when nothing matches.
String? selectBestVideoFormat(
  List<Map<String, dynamic>> videoFormats, {
  required int targetHeight,
  required String preferredCodec,
  String? fallbackRecommendedId,
}) {
  if (videoFormats.isEmpty) return fallbackRecommendedId;
  var matching =
      videoFormats.where((f) => _num(f, 'height') <= targetHeight).toList();
  if (matching.isEmpty) matching = List.of(videoFormats);
  final want = preferredCodec.toLowerCase();
  final codecHits = matching
      .where((f) => (f['vcodec'] as String? ?? '').toLowerCase().contains(want))
      .toList();
  final pool = codecHits.isNotEmpty ? codecHits : matching;
  pool.sort(_compareVideoDesc);
  return pool.first['format_id'] as String? ?? fallbackRecommendedId;
}

int _compareAudioDesc(Map<String, dynamic> a, Map<String, dynamic> b) {
  final aa = (a['abr'] as num?) ?? (a['tbr'] as num?) ?? 0;
  final ab = (b['abr'] as num?) ?? (b['tbr'] as num?) ?? 0;
  if (aa != ab) return ab.compareTo(aa);
  final ta = (a['tbr'] as num?) ?? 0;
  final tb = (b['tbr'] as num?) ?? 0;
  if (ta != tb) return tb.compareTo(ta);
  return (a['format_id'] as String? ?? '').compareTo(b['format_id'] as String? ?? '');
}

/// Best audio format id by descending bitrate (abr, fallback tbr).
String? selectBestAudioFormat(List<Map<String, dynamic>> audioFormats) {
  if (audioFormats.isEmpty) return null;
  final sorted = List.of(audioFormats)..sort(_compareAudioDesc);
  return sorted.first['format_id'] as String?;
}
