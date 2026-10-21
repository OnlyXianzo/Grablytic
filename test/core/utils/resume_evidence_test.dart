import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/utils/resume_evidence.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('resume-evidence-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('finds a .part file in a subfolder', () async {
    // #103: the probe used to list the download folder one level deep, while
    // the scan it guards walks recursively. A nested download had no
    // evidence, so the interrupted-downloads card never appeared.
    final nested = Directory('${root.path}/Show/Season 1')
      ..createSync(recursive: true);
    File('${nested.path}/episode.mp4.part').writeAsStringSync('x');

    expect(await hasPartialDlFiles([root.path]), isTrue);
  });

  test('finds an aria2 control file', () async {
    File('${root.path}/movie.mp4.aria2').writeAsStringSync('x');
    expect(await hasPartialDlFiles([root.path]), isTrue);
  });

  test('a finished download is not evidence', () async {
    File('${root.path}/movie.mp4').writeAsStringSync('x');
    File('${root.path}/notes.txt').writeAsStringSync('x');
    expect(await hasPartialDlFiles([root.path]), isFalse);
  });

  test('checks every root, not just the first', () async {
    final second = await Directory.systemTemp.createTemp('resume-second-');
    addTearDown(() async {
      if (await second.exists()) await second.delete(recursive: true);
    });
    File('${second.path}/late.mp4.part').writeAsStringSync('x');

    expect(await hasPartialDlFiles([root.path, second.path]), isTrue);
  });

  test('a missing or unreadable root is not an error', () async {
    expect(
      await hasPartialDlFiles(['${root.path}/does-not-exist', '']),
      isFalse,
    );
  });

  test('stops at the depth bound', () async {
    var dir = root;
    for (var i = 0; i < 8; i++) {
      dir = Directory('${dir.path}/d$i')..createSync();
    }
    File('${dir.path}/deep.mp4.part').writeAsStringSync('x');

    expect(await hasPartialDlFiles([root.path], maxDepth: 2), isFalse);
    expect(await hasPartialDlFiles([root.path]), isTrue);
  });

  test('does not walk symlinked directories', () async {
    final target = await Directory.systemTemp.createTemp('resume-link-');
    addTearDown(() async {
      if (await target.exists()) await target.delete(recursive: true);
    });
    File('${target.path}/x.mp4.part').writeAsStringSync('x');
    Link('${root.path}/link').createSync(target.path);

    expect(await hasPartialDlFiles([root.path]), isFalse);
  });
}
