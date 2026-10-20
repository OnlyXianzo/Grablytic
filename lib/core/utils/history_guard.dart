import '../database/download_history_db.dart';

/// Duplicate / already-downloaded guards (pure, unit-tested).
///
/// History records carry no extractor video id (schema v1), so identity is
/// derived from the URL: exact normalized match first, YouTube video-id
/// match second (covers watch?v=X vs youtu.be/X vs shorts/X, and the
/// downloaded-as-audio vs downloaded-as-video case).

/// Hosts that serve the same catalogue, keyed by "this is a short link".
const _youtuShortHosts = {'youtu.be', 'www.youtu.be', 'm.youtu.be'};

/// Hosts where the video id comes from `?v=` or a `/shorts|embed|live/` path.
const _youtubeHosts = {
  'youtube.com',
  'www.youtube.com',
  'm.youtube.com',
  'music.youtube.com',
  'youtube-nocookie.com',
  'www.youtube-nocookie.com',
};

/// A YouTube video id is exactly eleven URL-safe base64 characters.
final _videoIdPattern = RegExp(r'^[A-Za-z0-9_-]{11}$');

/// Collapses scheme/host case, `www.`, a default port and the fragment.
///
/// Two links to the same page that differ only in a `#t=30` timestamp used
/// to compare unequal, so the "already have" guard missed them for every
/// non-YouTube host (YouTube fell through to the video-id check).
String _normalizeUrl(String url) {
  Uri? uri;
  try {
    uri = Uri.parse(url.trim());
  } catch (_) {
    return url.trim();
  }
  var host = uri.host.toLowerCase();
  if (host.startsWith('www.')) host = host.substring(4);
  final scheme = uri.scheme.toLowerCase();
  final defaultPort = (scheme == 'http' && uri.port == 80) ||
      (scheme == 'https' && uri.port == 443);
  var path = uri.path;
  while (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  if (path == '/') path = '';
  final rebuilt = Uri(
    scheme: scheme,
    host: host,
    port: defaultPort ? null : (uri.hasPort ? uri.port : null),
    path: path,
    query: uri.hasQuery ? uri.query : null,
  );
  return rebuilt.toString();
}

/// Canonical video id for YouTube URLs, else null.
///
/// Hosts are matched exactly (plus the known `www.`/`m.`/`music.` prefixes)
/// rather than with `contains`: `youtube.com.example.net/watch?v=X` used to
/// yield the id `X`, so a look-alike URL was reported as "already have" and
/// the user's download was silently skipped.
String? extractVideoId(String url) {
  Uri? uri;
  try {
    uri = Uri.parse(url.trim());
  } catch (_) {
    return null;
  }
  final host = uri.host.toLowerCase();
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();

  String? checked(String? candidate) =>
      candidate != null && _videoIdPattern.hasMatch(candidate)
          ? candidate
          : null;

  if (_youtuShortHosts.contains(host)) {
    return segments.isEmpty ? null : checked(segments.first);
  }
  if (_youtubeHosts.contains(host)) {
    final v = checked(uri.queryParameters['v']);
    if (v != null) return v;
    if (segments.length >= 2 &&
        (segments[0] == 'shorts' ||
            segments[0] == 'embed' ||
            segments[0] == 'live')) {
      return checked(segments[1]);
    }
  }
  return null;
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
