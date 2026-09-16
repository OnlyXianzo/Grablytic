/// Guards for the Flutter↔engine trust boundary.
///
/// Strings arriving from the engine (finished-event file paths) or from
/// user-pasted text (proxy settings, pasted flag templates) must never
/// reach file deletion, image rendering, log export, or the network stack
/// verbatim. All helpers are pure and never throw.
import 'package:path/path.dart' as p;

/// Schemes allowed for outbound proxy settings.
const allowedProxySchemes = {
  'http',
  'https',
  'socks4',
  'socks5',
  'socks5h',
};

/// Returns a usable proxy value or null when [raw] must be dropped.
///
/// Requires a parseable absolute URI with an allowed scheme and a host.
/// Auth userinfo (user:pass@host, e.g. Tor on 127.0.0.1:9050) is preserved:
/// proxies legitimately point at loopback, so unlike media URLs there is
/// no private-host block here — only scheme + host validation that stops
/// pasted garbage (`--proxy http://evil:8080` as a "template") from
/// silently hijacking all subsequent fetches.
String? sanitizeProxy(String? raw) {
  if (raw == null) return null;
  final text = raw.trim();
  if (text.isEmpty || text.length > 1024) return null;
  final uri = Uri.tryParse(text);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  if (!allowedProxySchemes.contains(uri.scheme.toLowerCase())) return null;
  return text;
}

/// Strips any directory components from an export file name.
///
/// Handles both `/` and `\` separators, drops `..`/empty segments, and
/// falls back to [fallback] when nothing usable remains. Prevents
/// `displayName` traversal (`../../x`) from escaping the export folder.
String sanitizeExportFileName(String raw, {String fallback = 'export'}) {
  final parts = raw
      .split(RegExp(r'[\\/]'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty && s != '.' && s != '..')
      .toList();
  if (parts.isEmpty) return fallback;
  final name = parts.last;
  if (name.isEmpty || name == '.' || name == '..') return fallback;
  return name.length > 255 ? name.substring(0, 255) : name;
}

/// Normalizes an engine-reported file path, or null when unusable.
///
/// Requires a non-empty absolute path after normalization. Relative paths
/// and `.`/`..`-only input are rejected: engine paths must be absolute
/// locations of artifacts it just wrote.
String? sanitizeEngineFilePath(String? raw) {
  if (raw == null) return null;
  final text = raw.trim();
  if (text.isEmpty) return null;
  final normalized = p.normalize(text);
  if (!p.isAbsolute(normalized)) return null;
  return normalized;
}

/// True when [filePath] resolves inside [baseDir] (symlink-aware where the
/// platform resolves them; string-level otherwise). Never throws.
bool isPathWithinDir(String filePath, String baseDir) {
  try {
    final base = p.normalize(p.absolute(baseDir));
    final target = p.normalize(p.absolute(filePath));
    return p.isWithin(base, target) || p.equals(base, target);
  } catch (_) {
    return false;
  }
}
