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
  final q = qualityCeiling.toLowerCase().trim();
  if (q == '4k' || q == '2160p') return 2160;
  if (q == '1440p' || q == '2k') return 1440;
  if (q == '1080p') return 1080;
  if (q == '720p') return 720;
  if (q == '480p' || presetId == 'preset_480p') return 480;
  if (q == '360p') return 360;
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
  return (a['format_id'] as String? ?? '').compareTo(
    b['format_id'] as String? ?? '',
  );
}

/// Best video format id for [targetHeight] preferring [preferredCodec].
/// Returns [fallbackRecommendedId] (or null) when nothing matches.
///
/// Orientation-neutral: a format matches when EITHER its height OR its
/// width fits the ceiling, so portrait reels (720x1280/1080x1920) are not
/// down-picked to 540x960 under a 1080p ceiling the way a height-only
/// filter does (same bug class as the engine ladder's audio-only
/// fallthrough). Entries without dimensions (0/0) still match, preserving
/// the old null-safe behavior.
String? selectBestVideoFormat(
  List<Map<String, dynamic>> videoFormats, {
  required int targetHeight,
  required String preferredCodec,
  String? fallbackRecommendedId,
}) {
  if (videoFormats.isEmpty) return fallbackRecommendedId;
  // Orientation-neutral ceiling: match when a KNOWN dimension fits.
  // Unknown (null) dimensions never match on their own — otherwise a
  // width-less 1440p entry would slip a 1080p ceiling — but the
  // empty-match fallback below preserves the old leniency.
  var matching = videoFormats.where((f) {
    final h = f['height'] as num?;
    final w = f['width'] as num?;
    return (h != null && h <= targetHeight) || (w != null && w <= targetHeight);
  }).toList();
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
  return (a['format_id'] as String? ?? '').compareTo(
    b['format_id'] as String? ?? '',
  );
}

/// Best audio format id by descending bitrate (abr, fallback tbr).
String? selectBestAudioFormat(List<Map<String, dynamic>> audioFormats) {
  if (audioFormats.isEmpty) return null;
  final sorted = List.of(audioFormats)..sort(_compareAudioDesc);
  return sorted.first['format_id'] as String?;
}
