import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/utils/app_logger.dart';
import '../../../providers/search_provider.dart';
import '../../settings/screens/cookie_webview_screen.dart';
import '../../settings/screens/settings_screen.dart';
import '../widgets/error_recovery_card.dart';
import 'format_picker_screen.dart';

class SearchResultsScreen extends ConsumerStatefulWidget {
  final String initialQuery;
  final String initialSite;

  const SearchResultsScreen({
    super.key,
    required this.initialQuery,
    this.initialSite = 'youtube',
  });

  @override
  ConsumerState<SearchResultsScreen> createState() => _SearchResultsScreenState();
}

class _SearchResultsScreenState extends ConsumerState<SearchResultsScreen> {
  late final TextEditingController _searchController;
  late final FocusNode _searchFocusNode;
  late String _currentSite;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.initialQuery);
    _searchFocusNode = FocusNode();
    _currentSite = widget.initialSite;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.initialQuery.trim().isNotEmpty) {
        ref.read(searchProvider.notifier).search(
              widget.initialQuery,
              site: _currentSite,
            );
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _triggerSearch() {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;
    _searchFocusNode.unfocus();
    ref.read(searchProvider.notifier).search(query, site: _currentSite);
  }

  void _onSiteChanged(String site) {
    if (_currentSite == site) return;
    setState(() => _currentSite = site);
    final query = _searchController.text.trim();
    if (query.isNotEmpty) {
      ref.read(searchProvider.notifier).search(query, site: site);
    }
  }

  String _formatDuration(int? seconds) {
    if (seconds == null || seconds <= 0) return '';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    if (m >= 60) {
      final h = m ~/ 60;
      final remM = m % 60;
      return '$h:${remM.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  void _openFormatPicker(SearchResultEntry entry) {
    AppLogger.info('Search result selected: ${entry.title} (${entry.url})', tag: 'SearchResultsScreen');
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FormatPickerScreen(
          url: entry.url,
          title: entry.title,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final searchState = ref.watch(searchProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Search Results'),
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.primary,
        elevation: 0,
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Search Input Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.4),
                  ),
                  color: colorScheme.surfaceContainerLowest,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: TextField(
                          controller: _searchController,
                          focusNode: _searchFocusNode,
                          decoration: InputDecoration(
                            hintText: 'Search video or audio...',
                            hintStyle: TextStyle(
                              color: colorScheme.outline.withValues(alpha: 0.5),
                            ),
                            border: InputBorder.none,
                            isDense: true,
                          ),
                          style: textTheme.bodyMedium,
                          onSubmitted: (_) => _triggerSearch(),
                        ),
                      ),
                    ),
                    if (_searchController.text.isNotEmpty)
                      Semantics(
                        button: true,
                        label: 'Clear search',
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () {
                            _searchController.clear();
                            setState(() {});
                          },
                          child: const SizedBox(
                            width: 48,
                            height: 48,
                            child: Icon(Icons.clear, size: 20),
                          ),
                        ),
                      ),
                    Semantics(
                      button: true,
                      label: 'Execute search',
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Material(
                          color: colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(8),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: _triggerSearch,
                            child: SizedBox(
                              width: 44,
                              height: 44,
                              child: Icon(
                                Icons.search,
                                color: colorScheme.onPrimaryContainer,
                                size: 20,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Site selector chips (YouTube, SoundCloud)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  Semantics(
                    button: true,
                    label: 'Search on YouTube',
                    child: ChoiceChip(
                      avatar: const Icon(Icons.play_circle_outline, size: 16),
                      label: const Text('YouTube'),
                      selected: _currentSite == 'youtube',
                      onSelected: (_) => _onSiteChanged('youtube'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Semantics(
                    button: true,
                    label: 'Search on SoundCloud',
                    child: ChoiceChip(
                      avatar: const Icon(Icons.music_note_outlined, size: 16),
                      label: const Text('SoundCloud'),
                      selected: _currentSite == 'soundcloud',
                      onSelected: (_) => _onSiteChanged('soundcloud'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),

            // Main Content Area
            Expanded(
              child: _buildBody(context, ref, searchState, colorScheme, textTheme),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    WidgetRef ref,
    SearchState state,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    if (state.isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              'Searching on ${_currentSite == "soundcloud" ? "SoundCloud" : "YouTube"}...',
              style: textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    if (state.hasError) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ErrorRecoveryCard(
              errorType: state.errorType,
              errorMessage: state.errorMessage,
              onRetry: () => ref.read(searchProvider.notifier).retry(),
              onOpenCookies: () {
                final siteName = _currentSite == 'soundcloud' ? 'SoundCloud' : 'YouTube';
                final loginUrl = _currentSite == 'soundcloud'
                    ? 'https://soundcloud.com/signin'
                    : 'https://accounts.google.com/ServiceLogin';
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => CookieWebViewScreen(
                      loginUrl: loginUrl,
                      siteName: siteName,
                    ),
                  ),
                );
              },
              onOpenProxy: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const SettingsScreen(),
                  ),
                );
              },
            ),
          ],
        ),
      );
    }

    if (state.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Semantics(
                label: 'No search results icon',
                child: Icon(
                  Icons.search_off,
                  size: 64,
                  color: colorScheme.outline.withValues(alpha: 0.5),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'No results found',
                style: textTheme.titleMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Try different keywords or check your network connection.',
                style: textTheme.bodyMedium?.copyWith(
                  color: colorScheme.outline,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Text(
            '${state.results.length} results for "${state.query}"',
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            itemCount: state.results.length,
            itemBuilder: (context, index) {
              final item = state.results[index];
              final durationStr = _formatDuration(item.durationSeconds);

              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Card(
                  elevation: 0,
                  color: colorScheme.surfaceContainerLow,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                      color: colorScheme.outlineVariant.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Semantics(
                    button: true,
                    label: '${item.title}${item.uploader != null ? ", by ${item.uploader}" : ""}${durationStr.isNotEmpty ? ", duration $durationStr" : ""}. Tap to choose download formats',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _openFormatPicker(item),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Thumbnail container
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                width: 100,
                                height: 60,
                                color: colorScheme.surfaceContainerHighest,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    if (item.thumbnailUrl != null &&
                                        item.thumbnailUrl!.isNotEmpty)
                                      Image.network(
                                        item.thumbnailUrl!,
                                        fit: BoxFit.cover,
                                        errorBuilder:
                                            (context, error, stackTrace) =>
                                                Icon(
                                          Icons.video_library,
                                          color: colorScheme.outline,
                                          size: 28,
                                        ),
                                      )
                                    else
                                      Icon(
                                        Icons.video_library,
                                        color: colorScheme.outline,
                                        size: 28,
                                      ),
                                    if (durationStr.isNotEmpty)
                                      Positioned(
                                        bottom: 4,
                                        right: 4,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 4,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.black.withValues(alpha: 0.75),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            durationStr,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 10,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),

                            // Result details
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  if (item.uploader != null)
                                    Text(
                                      item.uploader!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: textTheme.bodySmall?.copyWith(
                                        color: colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                ],
                              ),
                            ),

                            // Action button
                            Semantics(
                              button: true,
                              label: 'Pick formats for ${item.title}',
                              child: Container(
                                width: 48,
                                height: 48,
                                alignment: Alignment.center,
                                child: Icon(
                                  Icons.chevron_right,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
