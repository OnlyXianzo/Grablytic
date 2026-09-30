import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/utils/link_importer.dart';

void main() {
  group('extractLinks plain-text mode', () {
    test('parses one URL per line', () {
      const text = 'https://www.instagram.com/p/ABC123xyz_0/\n'
          'https://www.instagram.com/reel/DEF456uvw_1/';
      expect(extractLinks(text), [
        'https://www.instagram.com/p/ABC123xyz_0/',
        'https://www.instagram.com/reel/DEF456uvw_1/',
      ]);
    });

    test('skips blanks, trims, skips # comments', () {
      const text = '   \n'
          '# a comment\n'
          '   https://www.instagram.com/p/ABC123xyz_0/   \n'
          '   # indented comment\n'
          '\n';
      expect(
        extractLinks(text),
        ['https://www.instagram.com/p/ABC123xyz_0/'],
      );
    });

    test('extracts first URL from noisy lines', () {
      const text = '1. https://www.instagram.com/p/ABC123xyz_0/ cool post\n'
          'check this out: https://www.instagram.com/reel/DEF456uvw_1/.';
      expect(extractLinks(text), [
        'https://www.instagram.com/p/ABC123xyz_0/',
        'https://www.instagram.com/reel/DEF456uvw_1/',
      ]);
    });

    test('skips garbage lines', () {
      const text = 'just some prose\n'
          'not a link at all\n'
          'https://www.instagram.com/p/ABC123xyz_0/\n';
      expect(
        extractLinks(text),
        ['https://www.instagram.com/p/ABC123xyz_0/'],
      );
    });

    test('expands bare shortcodes', () {
      expect(
        extractLinks('C8abcXYZ123'),
        ['https://www.instagram.com/p/C8abcXYZ123/'],
      );
    });

    test('dedupes preserving first-seen order', () {
      const text = 'https://www.instagram.com/p/BBB222yyy_1/\n'
          'https://www.instagram.com/p/AAA111xxx_0/\n'
          'https://www.instagram.com/p/BBB222yyy_1/\n';
      expect(extractLinks(text), [
        'https://www.instagram.com/p/BBB222yyy_1/',
        'https://www.instagram.com/p/AAA111xxx_0/',
      ]);
    });

    test('caps at 500 with overflow count', () {
      final lines = List.generate(
        520,
        (i) => 'https://www.instagram.com/p/CODE${i}abX${i}0/',
      );
      final result = parseLinkImport(lines.join('\n'));
      expect(result.links, hasLength(maxBatchLinks));
      expect(result.overflowCount, 20);
      expect(result.totalFound, 520);
      // Order preserved: first link first.
      expect(result.links.first, lines.first);
    });

    test('empty input yields empty result', () {
      final result = parseLinkImport('   \n # only comments\n');
      expect(result.links, isEmpty);
      expect(result.overflowCount, 0);
      expect(result.totalFound, 0);
    });
  });

  group('extractLinks CSV mode', () {
    test('finds instagram links inside CSV cells', () {
      const csv = 'permalink,caption,likes\n'
          'https://www.instagram.com/p/ABC123xyz_0/,nice pic,42\n'
          'https://www.instagram.com/reel/DEF456uvw_1/,reel!,7\n';
      expect(
        extractLinks(csv, csvMode: true),
        [
          'https://www.instagram.com/p/ABC123xyz_0/',
          'https://www.instagram.com/reel/DEF456uvw_1/',
        ],
      );
    });

    test('handles quoted cells containing commas', () {
      const csv = 'url,caption\n'
          '"https://www.instagram.com/p/ABC123xyz_0/","a, b, c"\n';
      expect(
        extractLinks(csv, csvMode: true),
        ['https://www.instagram.com/p/ABC123xyz_0/'],
      );
    });

    test('expands bare shortcode cells, ignores header words', () {
      const csv = 'shortcode,likes,caption\n'
          'C8abcXYZ123,42,sunset\n';
      expect(
        extractLinks(csv, csvMode: true),
        ['https://www.instagram.com/p/C8abcXYZ123/'],
      );
    });

    test('normalizes scheme-less instagram cells', () {
      const csv = 'permalink\n'
          'instagram.com/p/ABC123xyz_0\n';
      expect(
        extractLinks(csv, csvMode: true),
        ['https://instagram.com/p/ABC123xyz_0'],
      );
    });

    test('ignores numeric and prose cells', () {
      const csv = 'likes,caption,date\n42,sunset vibes,2026-01-01\n';
      expect(extractLinks(csv, csvMode: true), isEmpty);
    });

    test('dedupes and caps in CSV mode too', () {
      final rows = List.generate(
        505,
        (i) => 'https://www.instagram.com/p/CSV${i}abX${i}0/,cap,$i',
      );
      final result =
          parseLinkImport('url,cap,n\n${rows.join('\n')}', csvMode: true);
      expect(result.links, hasLength(maxBatchLinks));
      expect(result.overflowCount, 5);
      expect(result.totalFound, 505);
    });
  });
}
