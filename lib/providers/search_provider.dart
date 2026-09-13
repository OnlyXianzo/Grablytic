import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/engine/engine_provider.dart';
import '../core/engine/engine_service.dart';
import '../core/utils/app_logger.dart';
import 'engine_status_provider.dart';

class SearchResultEntry {
  final int index;
  final String title;
  final String url;
  final int? durationSeconds;
  final String? thumbnailUrl;
  final String? uploader;
  final bool isAvailable;

  const SearchResultEntry({
    required this.index,
    required this.title,
    required this.url,
    this.durationSeconds,
    this.thumbnailUrl,
    this.uploader,
    this.isAvailable = true,
  });

  factory SearchResultEntry.fromJson(Map<String, dynamic> json) {
    return SearchResultEntry(
      index: (json['index'] as num?)?.toInt() ?? 0,
      title: json['title'] as String? ?? 'Untitled',
      url: json['url'] as String? ?? '',
      durationSeconds: (json['duration_seconds'] as num?)?.toInt(),
      thumbnailUrl: json['thumbnail_url'] as String?,
      uploader: json['uploader'] as String?,
      isAvailable: json['is_available'] as bool? ?? true,
    );
  }
}

class SearchState {
  final bool isLoading;
  final String query;
  final String site;
  final List<SearchResultEntry> results;
  final String? errorType;
  final String? errorMessage;

  const SearchState({
    this.isLoading = false,
    this.query = '',
    this.site = 'youtube',
    this.results = const [],
    this.errorType,
    this.errorMessage,
  });

  bool get hasError => errorMessage != null;
  bool get isEmpty => !isLoading && !hasError && results.isEmpty;
}

class SearchNotifier extends StateNotifier<SearchState> {
  final Ref _ref;
  final EngineService _engine;

  SearchNotifier(this._ref, this._engine) : super(const SearchState());

  Future<void> search(
    String query, {
    String site = 'youtube',
    int limit = 20,
    Map<String, dynamic>? config,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;

    state = SearchState(
      isLoading: true,
      query: trimmed,
      site: site,
      results: const [],
    );

    AppLogger.info('Initiating search: "$trimmed" on $site', tag: 'SearchNotifier');

    try {
      // Milestone 4: Gate on engineStatusProvider.ready before initiating engine query
      final status = await _ref.read(engineStatusProvider.future);
      if (!status.ready) {
        state = SearchState(
          isLoading: false,
          query: trimmed,
          site: site,
          errorType: 'ERROR_ENGINE_NOT_READY',
          errorMessage: status.error ?? 'Engine is not ready',
        );
        return;
      }

      final result = await _engine.search(
        query: trimmed,
        site: site,
        limit: limit,
        config: config ?? {
          'cookies_path': null,
          'proxy': null,
          'verbose': false,
        },
      );

      if (result['success'] == true) {
        final rawEntries = (result['entries'] as List?) ?? [];
        final entries = rawEntries
            .whereType<Map>()
            .map((m) => SearchResultEntry.fromJson(Map<String, dynamic>.from(m)))
            .toList();

        state = SearchState(
          isLoading: false,
          query: trimmed,
          site: site,
          results: entries,
        );
        AppLogger.info('Search succeeded with ${entries.length} results', tag: 'SearchNotifier');
      } else {
        final errType = result['error_type'] as String? ?? 'ERROR_SEARCH_FAILED';
        final errMessage = result['error_message'] as String? ?? 'Failed to search';
        state = SearchState(
          isLoading: false,
          query: trimmed,
          site: site,
          errorType: errType,
          errorMessage: errMessage,
        );
        AppLogger.warn('Search failed: $errType — $errMessage', tag: 'SearchNotifier');
      }
    } catch (e) {
      AppLogger.error('Search threw exception', error: e, tag: 'SearchNotifier');
      state = SearchState(
        isLoading: false,
        query: trimmed,
        site: site,
        errorType: 'ERROR_SEARCH_FAILED',
        errorMessage: e.toString(),
      );
    }
  }

  void retry() {
    if (state.query.isNotEmpty) {
      search(state.query, site: state.site);
    }
  }

  void clear() {
    state = const SearchState();
  }
}

final searchProvider = StateNotifierProvider<SearchNotifier, SearchState>((ref) {
  final engine = ref.watch(engineProvider);
  return SearchNotifier(ref, engine);
});
