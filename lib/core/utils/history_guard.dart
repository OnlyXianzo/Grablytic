import '../database/download_history_db.dart';

/// Duplicate / already-downloaded guards (pure, unit-tested).
///
/// History records carry no extractor video id (schema v1), so identity is
/// derived from the URL: exact normalized match first, YouTube video-id
/// match second (covers watch?v=X vs youtu.be/X vs shorts/X, and the
/// downloaded-as-audio vs downloaded-as-video case).

/// Canonical video id for YouTube URLs, else null.
String? extractVideoId(String url) {
  Uri? uri;
  try {
    uri = Uri.parse(url.trim());
  } catch (_) {
    return null;
  }
  final host = uri.host.toLowerCase();
  if (host.contains('youtu.be')) {
    final seg = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    return seg.isEmpty ? null : seg.first;
  }
  if (host.contains('youtube.com') || host.contains('youtube-nocookie.com')) {
    final v = uri.queryParameters['v'];
    if (v != null && v.isNotEmpty) return v;
    final seg = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (seg.length >= 2 && (seg[0] == 'shorts' || seg[0] == 'embed' || seg[0] == 'live')) {
      return seg[1];
    }
  }
  return null;
}

String _normalizeUrl(String url) {
  var u = url.trim();
  while (u.endsWith('/')) {
    u = u.substring(0, u.length - 1);
  }
  return u;
}

/// True when [a] and [b] point at the same video.
bool isSameVideo(String a, String b) {
  if (_normalizeUrl(a) == _normalizeUrl(b)) return true;
  final ida = extractVideoId(a);
  if (ida == null) return false;
  return ida == extractVideoId(b);
}

/// First completed record for the same video, else null.
DownloadRecord? findDuplicate(List<DownloadRecord> records, String url) {
  for (final r in records) {
    if (r.status != 'completed') continue;
    if (isSameVideo(r.url, url)) return r;
  }
  return null;
}
