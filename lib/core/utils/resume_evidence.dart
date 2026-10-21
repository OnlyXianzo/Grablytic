import 'dart:io';

/// Suffixes that count as evidence of an interrupted download.
///
/// `.part` is what the engine's resume scan yields; `.aria2` is the control
/// file aria2c leaves beside it. Either one means a transfer stopped
/// mid-flight, which is the only reason the interrupted-downloads card
/// exists.
const List<String> partialFileSuffixes = ['.part', '.aria2'];

/// A shared inspection budget, so one pathological folder cannot make the
/// probe walk a whole drive.
class _Budget {
  _Budget(this.remaining);
  int remaining;
}

/// Whether any of [roots] holds a partial file.
///
/// This is the evidence the home screen uses to decide whether an interrupted
/// download is worth starting the Python engine for. It used to look at one
/// directory, one level deep, for `.part` only — while the scan it guards
/// walks the cache *and* download directories recursively. A download in a
/// subfolder therefore had no evidence to find, so the card never appeared for
/// exactly the users who needed it.
///
/// Bounded on both axes ([maxDepth] per root, [maxEntries] overall) and
/// symlinks are not followed, matching the engine's scan.
Future<bool> hasPartialDlFiles(
  Iterable<String> roots, {
  int maxDepth = 4,
  int maxEntries = 2000,
}) async {
  final budget = _Budget(maxEntries);
  for (final root in roots) {
    if (root.isEmpty) continue;
    if (await _dirHasPartial(root, 0, maxDepth, budget)) return true;
    if (budget.remaining <= 0) return false;
  }
  return false;
}

Future<bool> _dirHasPartial(
  String dir,
  int depth,
  int maxDepth,
  _Budget budget,
) async {
  if (depth > maxDepth) return false;
  final subdirs = <String>[];
  try {
    await for (final entity in Directory(dir).list(followLinks: false)) {
      if (budget.remaining-- <= 0) return false;
      final path = entity.path;
      if (entity is Directory) {
        subdirs.add(path);
        continue;
      }
      for (final suffix in partialFileSuffixes) {
        if (path.endsWith(suffix)) return true;
      }
    }
  } on FileSystemException {
    // Missing, unreadable, or permission-denied: no evidence from here.
    return false;
  }
  for (final subdir in subdirs) {
    if (await _dirHasPartial(subdir, depth + 1, maxDepth, budget)) return true;
    if (budget.remaining <= 0) return false;
  }
  return false;
}
