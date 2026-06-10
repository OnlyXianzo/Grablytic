import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/database/download_history_db.dart';

final downloadHistoryDbProvider = Provider<DownloadHistoryDb>((ref) {
  return DownloadHistoryDb.instance;
});

final downloadHistoryProvider =
    FutureProvider.autoDispose<List<DownloadRecord>>((ref) {
  final db = ref.watch(downloadHistoryDbProvider);
  final search = ref.watch(downloadHistorySearchProvider);
  final status = ref.watch(downloadHistoryStatusFilterProvider);
  return db.getAll(search: search, statusFilter: status);
});

final downloadHistorySearchProvider = StateProvider<String>((ref) => '');

final downloadHistoryStatusFilterProvider =
    StateProvider<String?>((ref) => null);

final downloadHistoryProviderFamily =
    FutureProvider.autoDispose.family<DownloadRecord?, String>((ref, id) {
  final db = ref.watch(downloadHistoryDbProvider);
  return db.getById(id);
});
