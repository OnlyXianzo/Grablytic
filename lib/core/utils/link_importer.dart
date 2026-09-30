/// Pure batch-link importer: text/CSV -> Instagram (or generic) URLs.
///
/// No I/O here on purpose — file reading lives in the UI layer
/// ([BatchImportScreen]) so this module stays unit-testable without
/// plugins or the filesystem.
///
/// Supported inputs:
/// * Plain `.txt` (one URL per line): blank lines and `#` comment lines
///   are skipped, each remaining line is trimmed and its first `http(s)`
///   token is kept. A bare Instagram shortcode line (e.g. `C8abcXYZ123`)
///   is expanded to `https://www.instagram.com/p/<code>/`.
/// * Exporter CSVs (`csvMode: true`): cells are split quote-aware, every
///   `http(s)` token inside a cell is kept, and bare shortcode cells are
///   expanded. Scheme-less `instagram.com/p|/reel/<code>` cells are
///   normalized to `https://...`.
///
/// Post-processing (both modes): dedupe preserving first-seen order,
/// then cap at [maxBatchLinks]; the surplus is reported as
/// [LinkImportResult.overflowCount] instead of being silently dropped.
library;

/// Hard cap: matches the "one URL per line, ~100 each" chunk workflow
/// with headroom for several chunks pasted at once.
const int maxBatchLinks = 500;

/// Result of [parseLinkImport].
class LinkImportResult {
  /// Deduplicated links, capped at [maxBatchLinks], first-seen order.
  final List<String> links;

  /// How many unique links were cut off by the cap (0 when under cap).
  final int overflowCount;

  /// Unique-link count before capping.
  final int totalFound;

  const LinkImportResult({
    required this.links,
    required this.overflowCount,
    required this.totalFound,
  });
}

/// Extract deduplicated links from [text] (capped at [maxBatchLinks]).
///
/// See [parseLinkImport] for the full rule set including the overflow
/// count. [csvMode] switches to quote-aware CSV cell scanning.
List<String> extractLinks(String text, {bool csvMode = false}) =>
    parseLinkImport(text, csvMode: csvMode).links;

/// Extract links plus overflow accounting. Pure; no I/O.
LinkImportResult parseLinkImport(String text, {bool csvMode = false}) {
  final found = csvMode ? _extractCsv(text) : _extractPlain(text);
  final seen = <String>{};
  final unique = <String>[];
  for (final link in found) {
    if (seen.add(link)) unique.add(link);
  }
  if (unique.length > maxBatchLinks) {
    return LinkImportResult(
      links: unique.sublist(0, maxBatchLinks),
      overflowCount: unique.length - maxBatchLinks,
      totalFound: unique.length,
    );
  }
  return LinkImportResult(
    links: unique,
    overflowCount: 0,
    totalFound: unique.length,
  );
}

// ---------------------------------------------------------------------------
// Plain-text mode
// ---------------------------------------------------------------------------

List<String> _extractPlain(String text) {
  final out = <String>[];
  for (final rawLine in text.split(RegExp(r'\r\n|\r|\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final url = _firstUrlToken(line);
    if (url != null) {
      out.add(url);
      continue;
    }
    final shortcode = _bareShortcode(line);
    if (shortcode != null) out.add(_expandShortcode(shortcode));
    // Anything else (prose, garbage) is skipped.
  }
  return out;
}

// ---------------------------------------------------------------------------
// CSV mode
// ---------------------------------------------------------------------------

List<String> _extractCsv(String text) {
  final out = <String>[];
  for (final rawLine in text.split(RegExp(r'\r\n|\r|\n'))) {
    if (rawLine.trim().isEmpty) continue;
    for (final cell in _splitCsvLine(rawLine)) {
      final trimmed = cell.trim().replaceAll(RegExp(r'^"|"$'), '').trim();
      if (trimmed.isEmpty) continue;
      var matched = false;
      for (final m in _urlPattern.allMatches(trimmed)) {
        final cleaned = _cleanUrl(m.group(0)!);
        if (cleaned != null) {
          out.add(cleaned);
          matched = true;
        }
      }
      if (matched) continue;
      final schemeless = _schemelessInstagram(trimmed);
      if (schemeless != null) {
        out.add(schemeless);
        continue;
      }
      final shortcode = _bareShortcode(trimmed);
      if (shortcode != null) out.add(_expandShortcode(shortcode));
    }
  }
  return out;
}

/// Minimal quote-aware CSV line splitter (handles `"a,b"` and `""`).
List<String> _splitCsvLine(String line) {
  final cells = <String>[];
  final buf = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (ch == '"') {
      if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
        buf.write('"');
        i++;
      } else {
        inQuotes = !inQuotes;
      }
    } else if ((ch == ',' || ch == ';' || ch == '\t') && !inQuotes) {
      cells.add(buf.toString());
      buf.clear();
    } else {
      buf.write(ch);
    }
  }
  cells.add(buf.toString());
  return cells;
}

// ---------------------------------------------------------------------------
// Shared token helpers
// ---------------------------------------------------------------------------

final RegExp _urlPattern = RegExp(r'https?://[^\s<>\x22\x27]+');

/// Matches scheme-less exporter cells like
/// `instagram.com/p/ABC/`, `www.instagram.com/reel/ABC`, `instagr.am/p/ABC`.
final RegExp _schemelessPattern = RegExp(
  r'^(?:www\.|m\.)?(?:instagram\.com|instagr\.am)/(?:p|reel|reels|tv)/[A-Za-z0-9_-]+/?(?:\?.*)?$',
  caseSensitive: false,
);

/// Header/garbage tokens that must never be treated as shortcodes.
const Set<String> _shortcodeStoplist = {
  'url',
  'link',
  'links',
  'caption',
  'captions',
  'likes',
  'comments',
  'date',
  'timestamp',
  'time',
  'type',
  'media',
  'media_url',
  'shortcode',
  'short_code',
  'id',
  'post',
  'posts',
  'video',
  'image',
  'images',
  'description',
  'title',
  'author',
  'username',
  'user',
  'permalink',
  'thumbnail',
  'photo',
  'photos',
  'reel',
  'reels',
  'album',
  'carousel',
  'sidecar',
  'igtv',
  'true',
  'false',
  'none',
  'null',
};

final RegExp _shortcodePattern = RegExp(r'^[A-Za-z0-9_-]{5,30}$');
final RegExp _shortcodeHasLetter = RegExp(r'[A-Za-z]');
final RegExp _shortcodeHasNonLower = RegExp(r'[A-Z0-9_-]');

String? _firstUrlToken(String line) {
  final m = _urlPattern.firstMatch(line);
  if (m == null) return null;
  return _cleanUrl(m.group(0)!);
}

/// Strip trailing punctuation/quotes the regex over-captures
/// (`"url",`, `url).`, `url...`) and reject empties.
String? _cleanUrl(String raw) {
  // \x22 = double quote, \x27 = single quote (kept out of the raw-string
  // delimiters; decoded by the RegExp engine itself).
  var url = raw.replaceAll(RegExp(r'[.,;:!?)\]}\x22\x27]+$'), '');
  url = url.replaceAll(RegExp(r'^[(\[{\x22\x27]+'), '');
  if (url.isEmpty) return null;
  if (!url.startsWith('http://') && !url.startsWith('https://')) return null;
  return url;
}

String? _schemelessInstagram(String cell) {
  if (!_schemelessPattern.hasMatch(cell)) return null;
  return 'https://$cell'.replaceAll(RegExp(r'^https:///+'), 'https://');
}

/// A bare shortcode is a 5–30 char base64url-ish token that is not a
/// known CSV header word. It must contain at least one letter (rejects
/// dates like `2026-01-01` and pure numbers) and at least one
/// uppercase/digit/`_`/`-` signal (rejects lowercase prose like
/// `sunset`). All-lowercase shortcodes are a deliberate blind spot:
/// real Instagram codes are mixed-case base64url, so this trades a
/// ~0.03% miss rate for near-zero false positives.
String? _bareShortcode(String token) {
  final t = token.trim().replaceAll(RegExp(r'^"|"$'), '').trim();
  if (!_shortcodePattern.hasMatch(t)) return null;
  if (_shortcodeStoplist.contains(t.toLowerCase())) return null;
  if (RegExp(r'^\d+$').hasMatch(t)) return null;
  if (!_shortcodeHasLetter.hasMatch(t)) return null;
  if (!_shortcodeHasNonLower.hasMatch(t)) return null;
  return t;
}

String _expandShortcode(String code) =>
    'https://www.instagram.com/p/$code/';
