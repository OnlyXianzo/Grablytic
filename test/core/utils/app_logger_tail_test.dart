import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/utils/app_logger.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('app_logger_tail_');
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<File> writeFile(String name, String content) async {
    final f = File('${tmp.path}/$name');
    await f.writeAsString(content);
    return f;
  }

  Future<File> writeBytes(String name, List<int> bytes) async {
    final f = File('${tmp.path}/$name');
    await f.writeAsBytes(bytes);
    return f;
  }

  group('AppLogger.readLogTailText contract', () {
    test('empty file -> text empty, not truncated, no error', () async {
      final f = await writeFile('empty.txt', '');
      final r = await AppLogger.readLogTailText(f);
      expect(r.text, '');
      expect(r.truncated, isFalse);
      expect(r.fileBytes, 0);
      expect(r.shownBytes, 0);
      expect(r.error, isNull);
    });

    test('sub-cap file -> full text, truncated=false', () async {
      const content = 'line1\nline2\nline3\n';
      final f = await writeFile('small.txt', content);
      final len = await f.length();
      final r = await AppLogger.readLogTailText(f);
      expect(r.text, content);
      expect(r.truncated, isFalse);
      expect(r.fileBytes, len);
      expect(r.shownBytes, len);
      expect(r.error, isNull);
    });

    test('over-cap file -> tail only, truncated=true, banner data correct',
        () async {
      // Build ~5KB file, read last 1KB.
      final sb = StringBuffer();
      for (var i = 0; i < 500; i++) {
        sb.writeln('line-${i.toString().padLeft(4, '0')} padding-xyz');
      }
      final content = sb.toString();
      final f = await writeFile('big.txt', content);
      final len = await f.length();
      expect(len, greaterThan(1024));

      final r = await AppLogger.readLogTailText(f, maxBytes: 1024);
      expect(r.error, isNull);
      expect(r.truncated, isTrue);
      expect(r.fileBytes, len);
      // Banner data: shown bytes within cap and within file size.
      expect(r.shownBytes, lessThanOrEqualTo(1024));
      expect(r.shownBytes, greaterThan(0));
      expect(r.shownBytes, lessThanOrEqualTo(r.fileBytes));
      // Tail only: must not contain the head, must end with file end.
      expect(r.text, isNot(contains('line-0000')));
      expect(content.endsWith(r.text), isTrue,
          reason: 'tail text must be a suffix of the full file');
      // shownBytes must match the bytes the text came from.
      expect(r.shownBytes, utf8.encode(r.text).length);
    });

    test('mid-line alignment -> first line whole (starts at boundary)',
        () async {
      // Fixed-width lines so the byte window almost surely cuts mid-line.
      final sb = StringBuffer();
      for (var i = 0; i < 200; i++) {
        sb.writeln('line-${i.toString().padLeft(3, '0')}');
      }
      final content = sb.toString();
      final f = await writeFile('align.txt', content);
      final r = await AppLogger.readLogTailText(f, maxBytes: 500);

      expect(r.error, isNull);
      expect(r.truncated, isTrue);
      expect(content.endsWith(r.text), isTrue);
      // The char before the tail in the full file must be a newline
      // (i.e. we start at a line boundary), unless the tail is the whole file.
      final startOffset = content.length - r.text.length;
      expect(startOffset, greaterThan(0));
      expect(content[startOffset - 1], '\n');
      // First line must be a complete line, not a fragment.
      final firstLine = r.text.split('\n').first;
      expect(firstLine, matches(RegExp(r'^line-\d{3}$')));
    });

    test('non-ASCII/emoji at cut point -> valid decode, at most one FFFD',
        () async {
      final sb = StringBuffer();
      for (var i = 0; i < 400; i++) {
        sb.writeln('emoji 😀🎉 test line $i padding-padding-padding');
      }
      final content = sb.toString();
      final f = await writeFile('emoji.txt', content);
      final len = await f.length();
      expect(len, greaterThan(1024));

      final r = await AppLogger.readLogTailText(f, maxBytes: 1024);
      expect(r.error, isNull);
      expect(r.truncated, isTrue);
      // Valid decode: no throw already proves it; emoji in the tail survive
      // (utf8.decode with allowMalformed, never String.fromCharCodes mojibake).
      expect(r.text, contains('😀'));
      final fffdCount =
          r.text.runes.where((c) => c == 0xFFFD).length;
      expect(fffdCount, lessThanOrEqualTo(1),
          reason: 'cutting mid-codepoint yields at most one replacement char');
    });

    test('missing file -> error set, no throw', () async {
      final f = File('${tmp.path}/does-not-exist-${DateTime.now().microsecondsSinceEpoch}.txt');
      var threw = false;
      late ({String text, bool truncated, int fileBytes, int shownBytes, String? error}) r;
      try {
        r = await AppLogger.readLogTailText(f);
      } catch (_) {
        threw = true;
      }
      expect(threw, isFalse, reason: 'must never throw');
      // ignore: unnecessary_null_comparison (r assigned iff no throw)
      expect(r.text, '');
      expect(r.truncated, isFalse);
      expect(r.error, isNotNull);
      expect(r.error!, isNotEmpty);
    });

    test('maxLines cap on small-bytes-many-lines file', () async {
      final sb = StringBuffer();
      for (var i = 0; i < 50; i++) {
        sb.writeln('row-$i');
      }
      final content = sb.toString();
      final f = await writeFile('manylines.txt', content);
      final len = await f.length();
      // Sanity: file is small in bytes (< default 100KB cap).
      expect(len, lessThan(100 * 1024));

      final r = await AppLogger.readLogTailText(f, maxLines: 10);
      expect(r.error, isNull);
      expect(r.truncated, isTrue);
      expect(r.fileBytes, len);
      // Last 10 logical lines.
      final expectedLines =
          List.generate(50, (i) => 'row-$i').sublist(40);
      final expectedText = '${expectedLines.join('\n')}\n';
      expect(r.text, expectedText);
      expect(r.shownBytes, utf8.encode(expectedText).length);
    });

    test('bytes file written with raw UTF8 decodes without mojibake',
        () async {
      // Guard against the String.fromCharCodes regression: raw bytes must go
      // through utf8.decode(allowMalformed: true).
      final content = 'héllo wörld 😀\nsecond line ✓\n';
      final f = await writeBytes('utf8.txt', utf8.encode(content));
      final r = await AppLogger.readLogTailText(f);
      expect(r.error, isNull);
      expect(r.text, content);
      expect(r.text, contains('😀'));
      expect(r.text, contains('✓'));
    });
  });
}
