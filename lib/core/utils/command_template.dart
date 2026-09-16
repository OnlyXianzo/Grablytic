/// Opt-in command-template application (safe subset, pure, unit-tested).
///
/// Templates are user-typed yt-dlp CLI fragments (validated at input by
/// `validateTemplateArgs`, which already blocks path-escape flags). This
/// maps the SAFE subset onto exact engine config keys; everything else is
/// reported in `ignored` and never applied. Explicit format ids picked in
/// the UI always win — templates never touch them.
import 'trust_boundary.dart';

class ParsedTemplate {
  final Map<String, dynamic> config;
  final List<String> ignored;

  const ParsedTemplate({required this.config, required this.ignored});
}

List<String> _tokenize(String args) {
  final tokens = <String>[];
  final buf = StringBuffer();
  String? quote;
  for (var i = 0; i < args.length; i++) {
    final c = args[i];
    if (quote != null) {
      if (c == quote) {
        quote = null;
      } else {
        buf.write(c);
      }
    } else if (c == '"' || c == "'") {
      quote = c;
    } else if (c.trim().isEmpty) {
      if (buf.isNotEmpty) {
        tokens.add(buf.toString());
        buf.clear();
      }
    } else {
      buf.write(c);
    }
  }
  if (buf.isNotEmpty) tokens.add(buf.toString());
  return tokens;
}

ParsedTemplate parseTemplateConfig(String args) {
  final config = <String, dynamic>{};
  final ignored = <String>[];
  final tokens = _tokenize(args);
  bool? writesubs;
  var i = 0;

  String? takeValue(String flag) {
    if (i + 1 < tokens.length && !tokens[i + 1].startsWith('-')) {
      i++;
      return tokens[i];
    }
    return null;
  }

  String? splitFlag(String token, String flag) {
    if (token == flag) return takeValue(flag);
    if (token.startsWith('$flag=')) return token.substring(flag.length + 1);
    return null;
  }

  bool flagHit(String token, List<String> names) => names.contains(token);

  while (i < tokens.length) {
    final t = tokens[i];
    if (flagHit(t, ['--write-sub', '--write-subs'])) {
      writesubs = true;
    } else if (flagHit(t, ['--no-write-sub', '--no-write-subs'])) {
      writesubs = false;
    } else if (flagHit(t, ['--write-auto-sub', '--write-auto-subs'])) {
      config['writeautomaticsub'] = true;
    } else if (flagHit(t, ['--no-write-auto-sub', '--no-write-auto-subs'])) {
      config['writeautomaticsub'] = false;
    } else if (flagHit(t, ['--embed-subs'])) {
      config['embedsubtitles'] = true;
    } else if (flagHit(t, ['--no-embed-subs'])) {
      config['embedsubtitles'] = false;
    } else if (flagHit(t, ['--write-description'])) {
      config['write_description'] = true;
    } else if (flagHit(t, ['--no-write-description'])) {
      config['write_description'] = false;
    } else if (t == '--sub-langs' || t.startsWith('--sub-langs=')) {
      final v = splitFlag(t, '--sub-langs');
      if (v != null && v.isNotEmpty) {
        config['subtitleslangs'] = v.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      } else {
        ignored.add(t);
      }
    } else if (t == '--sponsorblock-remove' || t.startsWith('--sponsorblock-remove=')) {
      final v = splitFlag(t, '--sponsorblock-remove');
      if (v != null && v.isNotEmpty) {
        config['sponsorblock_cats'] =
            v.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      } else {
        ignored.add(t);
      }
    } else if (t == '--merge-output-format' || t == '--remux-video' ||
        t.startsWith('--merge-output-format=') || t.startsWith('--remux-video=')) {
      final flag = t.startsWith('--remux-video') ? '--remux-video' : '--merge-output-format';
      final v = splitFlag(t, flag);
      if (v != null && RegExp(r'^[a-zA-Z0-9]+$').hasMatch(v)) {
        config['container'] = v.toLowerCase();
      } else {
        ignored.add(t);
      }
    } else if (t == '--concurrent-fragments' || t.startsWith('--concurrent-fragments=')) {
      final v = splitFlag(t, '--concurrent-fragments');
      final n = int.tryParse(v ?? '');
      // Loop-4 low-end default (engine DEFAULT_CFG is 2 as well).
      config['concurrent_fragments'] = n == null ? 2 : n.clamp(1, 16);
      if (n == null) ignored.add(t);
    } else if (t == '--socket-timeout' || t.startsWith('--socket-timeout=')) {
      final v = splitFlag(t, '--socket-timeout');
      final n = int.tryParse(v ?? '');
      if (n != null && n > 0) {
        config['socket_timeout'] = n;
      } else {
        ignored.add(t);
      }
    } else if (t == '--proxy' || t.startsWith('--proxy=')) {
      final v = splitFlag(t, '--proxy');
      final clean = sanitizeProxy(v);
      if (clean != null) {
        config['proxy'] = clean;
      } else {
        ignored.add(t);
      }
    } else if (t == '--limit-rate' || t == '--rate-limit' ||
        t.startsWith('--limit-rate=') || t.startsWith('--rate-limit=')) {
      final flag = t.startsWith('--limit-rate') ? '--limit-rate' : '--rate-limit';
      final v = splitFlag(t, flag);
      if (v != null && v.isNotEmpty) {
        config['rate_limit'] = v;
      } else {
        ignored.add(t);
      }
    } else {
      ignored.add(t);
    }
    i++;
  }

  if (writesubs != null) config['writesubtitles'] = writesubs;
  if (config.containsKey('subtitleslangs') && !config.containsKey('writesubtitles')) {
    // Mirrors yt-dlp: --sub-langs implies --write-subs.
    config['writesubtitles'] = true;
  }
  return ParsedTemplate(config: config, ignored: ignored);
}
