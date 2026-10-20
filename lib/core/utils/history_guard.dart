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

/// Collapses scheme/host case, `www.`, a default port and the fragment.
///
/// Two links to the same page that differ only in a `#t=30` timestamp used
/// to compare unequal, so the "already have" guard missed them for every
/// non-YouTube host (YouTube fell through to the video-id check).
/// Also trims whitespace and trailing path slashes, including a lone root
/// slash. Preserves the query; parse failures return the trimmed input.
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
/// Accepts any nonempty ID without length or character validation. Short links
/// use the first path segment; other recognized hosts prefer `v` over a
/// `/shorts/`, `/embed/`, or `/live/` path. Parse failures return null.
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

  // No length validation: real YouTube ids are eleven characters, but
  // enforcing that here would turn every short/degenerate id in an
  // existing history record into "not the same video" and silently
  // re-download it. The defect being fixed is the host match, not the id.
  String? checked(String? candidate) =>
      candidate == null || candidate.isEmpty ? null : candidate;

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

/// Set-based membership test over completed history records.
///
/// `findDuplicate` walks the record list for every candidate, so the batch
/// pre-filter was O(items x completed records): a 500-entry playlist against
/// a 5,000-row history meant 2.5M URL comparisons before the first download
/// started. Building the two lookup tables once is O(n + m).
///
/// Same rule as [findDuplicate]: a normalized URL match, or a matching
/// YouTube video id.
class CompletedVideoIndex {
  CompletedVideoIndex._(this._urls, this._ids);

  /// Builds the index from records already filtered to `completed`.
  factory CompletedVideoIndex.fromRecords(List<DownloadRecord> records) {
    final urls = <String>{};
    final ids = <String>{};
    for (final record in records) {
      if (record.status != 'completed') continue;
      urls.add(_normalizeUrl(record.url));
      final id = extractVideoId(record.url);
      if (id != null) ids.add(id);
    }
    return CompletedVideoIndex._(urls, ids);
  }

  final Set<String> _urls;
  final Set<String> _ids;

  /// True when [url] matches a completed record.
  bool contains(String url) {
    if (_urls.contains(_normalizeUrl(url))) return true;
    final id = extractVideoId(url);
    return id != null && _ids.contains(id);
  }
}
