import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/utils/format_selector.dart';

Map<String, dynamic> _v(String id, int? height, String vcodec, {num? tbr, num? fps}) => {
      'format_id': id,
      'height': height,
      'vcodec': vcodec,
      ...?tbr == null ? null : {'tbr': tbr},
      ...?fps == null ? null : {'fps': fps},
    };

Map<String, dynamic> _a(String id, {num? abr, num? tbr, String acodec = 'opus'}) => {
      'format_id': id,
      ...?abr == null ? null : {'abr': abr},
      ...?tbr == null ? null : {'tbr': tbr},
      'acodec': acodec,
    };

void main() {
  group('targetHeightForCeiling', () {
    test('maps 4k/1080p/720p/480p/best ceilings', () {
      expect(targetHeightForCeiling('4k', 'preset_4k'), 2160);
      expect(targetHeightForCeiling('1080p', 'preset_1080p'), 1080);
      expect(targetHeightForCeiling('720p', 'preset_720p'), 720);
      expect(targetHeightForCeiling('480p', 'preset_480p'), 480);
      expect(targetHeightForCeiling('best', 'preset_best'), 99999);
    });
  });

  group('selectBestVideoFormat (P0-1: sort-then-first)', () {
    test('RED: unsorted list still yields best vp9 <=1080p, not .first', () {
      final formats = [
        _v('160', 144, 'avc1.4d401f', tbr: 200),
        _v('308', 1440, 'vp9', tbr: 9000),
        _v('248', 1080, 'vp9', tbr: 4000),
        _v('137', 1080, 'avc1.640028', tbr: 4500),
      ];
      expect(
        selectBestVideoFormat(formats, targetHeight: 1080, preferredCodec: 'vp9'),
        '248',
      );
    });

    test('falls back across codecs when preferred codec absent <=ceiling', () {
      final formats = [
        _v('160', 144, 'avc1.4d401f', tbr: 200),
        _v('137', 1080, 'avc1.640028', tbr: 4500),
      ];
      expect(
        selectBestVideoFormat(formats, targetHeight: 1080, preferredCodec: 'vp9'),
        '137',
      );
    });

    test('all formats above ceiling falls back to tallest available', () {
      final formats = [
        _v('313', 2160, 'vp9', tbr: 15000),
        _v('401', 2160, 'av01.0.12M.08', tbr: 12000),
      ];
      expect(
        selectBestVideoFormat(formats, targetHeight: 1080, preferredCodec: 'vp9'),
        '313',
      );
    });

    test('empty list returns fallback recommendation, else null', () {
      expect(
        selectBestVideoFormat([], targetHeight: 1080, preferredCodec: 'vp9',
            fallbackRecommendedId: '248'),
        '248',
      );
      expect(
        selectBestVideoFormat([], targetHeight: 1080, preferredCodec: 'vp9'),
        isNull,
      );
    });

    test('null heights never crash and never win over real heights', () {
      final formats = [
        {'format_id': 'x', 'vcodec': 'vp9'},
        _v('248', 1080, 'vp9', tbr: 4000),
      ];
      expect(
        selectBestVideoFormat(formats, targetHeight: 1080, preferredCodec: 'vp9'),
        '248',
      );
    });
  });

  group('selectBestAudioFormat (P0-2: max bitrate, not list order)', () {
    test('RED: unsorted audio still yields 251 opus 160k, not .first', () {
      final formats = [
        _a('249', abr: 50),
        _a('250', abr: 70),
        _a('251', abr: 160),
      ];
      expect(selectBestAudioFormat(formats.reversed.toList()), '251');
      expect(selectBestAudioFormat(formats), '251');
    });

    test('tbr fallback when abr missing', () {
      final formats = [
        _a('a1', tbr: 48),
        _a('a2', tbr: 128),
      ];
      expect(selectBestAudioFormat(formats), 'a2');
    });

    test('empty list returns null', () {
      expect(selectBestAudioFormat([]), isNull);
    });
  });
}
