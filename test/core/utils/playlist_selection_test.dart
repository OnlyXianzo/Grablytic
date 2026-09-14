import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/utils/download_config.dart';
import 'package:grablytic/core/utils/playlist_selection.dart';

void main() {
  group('isPlaylistUrl (mirrors engine detect_playlist)', () {
    test('matches playlist / channel / sets URLs', () {
      expect(isPlaylistUrl('https://youtube.com/watch?v=abc&list=PLxyz'),
          isTrue);
      expect(
          isPlaylistUrl('https://youtube.com/playlist?list=PLxyz'), isTrue);
      expect(isPlaylistUrl('https://youtube.com/channel/UCxyz'), isTrue);
      expect(isPlaylistUrl('https://youtube.com/c/ChannelName'), isTrue);
      expect(isPlaylistUrl('https://youtube.com/@ChannelName'), isTrue);
      expect(isPlaylistUrl('https://youtube.com/user/username'), isTrue);
      expect(isPlaylistUrl('https://example.com/sets/abc'), isTrue);
    });

    test('rejects single videos and unrelated URLs', () {
      expect(isPlaylistUrl('https://youtube.com/watch?v=dQw4w9WgXcQ'),
          isFalse);
      expect(isPlaylistUrl('https://youtu.be/dQw4w9WgXcQ'), isFalse);
      expect(isPlaylistUrl('https://twitter.com/username/status/123'),
          isFalse);
      expect(
          isPlaylistUrl('https://example.com/video.mp4'), isFalse);
    });
  });

  group('buildPlaylistItemsString (mirrors engine build_playlist_items)', () {
    test('1-based passthrough, no 0→1 adjustment', () {
      expect(buildPlaylistItemsString([2, 4, 7]), '2,4,7');
    });

    test('dedupes but keeps caller order', () {
      expect(buildPlaylistItemsString([3, 1, 3, 2]), '3,1,2');
    });

    test('empty returns empty string', () {
      expect(buildPlaylistItemsString([]), '');
    });

    test('digit strings accepted', () {
      expect(buildPlaylistItemsString(['1', ' 3 ']), '1,3');
    });

    test('invalid indices throw', () {
      for (final bad in [0, -2, 'abc', null, 2.5, true]) {
        expect(() => buildPlaylistItemsString([1, bad]),
            throwsArgumentError);
      }
    });
  });

  group('playlistDownloadConfig', () {
    test('emits engine contract keys only when set', () {
      final base = playlistDownloadConfig(selectedIndices: [1, 3]);
      expect(base, {'playlist_items': '1,3'});

      final rev = playlistDownloadConfig(
          selectedIndices: [1, 3], reverse: true);
      expect(rev,
          {'playlist_items': '1,3', 'playlist_rev': true});

      final rand = playlistDownloadConfig(
          selectedIndices: [2], shuffle: true);
      expect(rand,
          {'playlist_items': '2', 'playlist_rand': true});
    });
  });
}
