import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../home/screens/home_screen.dart';
import '../../library/screens/library_screen.dart';
import '../../settings/screens/settings_screen.dart';
import '../../../providers/download_provider.dart';
import '../../../providers/settings_provider.dart';
import '../../../core/engine/engine_provider.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int _currentIndex = 0;
  StreamSubscription<String>? _intentSubscription;

  @override
  void initState() {
    super.initState();
    _initSharedUrlListening();
  }

  @override
  void dispose() {
    _intentSubscription?.cancel();
    super.dispose();
  }

  void _initSharedUrlListening() {
    final engine = ref.read(engineProvider);
    _intentSubscription = engine.sharedUrlStream.listen((url) {
      _handleSharedUrl(url);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final sharedUrl = await engine.getSharedUrl();
      if (sharedUrl != null && sharedUrl.isNotEmpty) {
        _handleSharedUrl(sharedUrl);
      }
    });
  }

  void _handleSharedUrl(String url) {
    if (url.isEmpty) return;

    final settings = ref.read(settingsProvider);
    if (settings.autoStartDownloadOnShare) {
      final downloadId = const Uuid().v4();
      final config = <String, dynamic>{
        'container': settings.qualityCeiling == 'best' ? 'mkv' : 'mp4',
        'quality_ceiling': settings.qualityCeiling,
        'audio_only': settings.audioOnly,
      };

      ref.read(engineProvider).startDownload(
        url: url,
        downloadId: downloadId,
        config: config,
        networkType: 'wifi',
      );

      ref.read(downloadProvider.notifier).addDownload(
        DownloadItem(
          id: downloadId,
          title: url,
          url: url,
          status: 'downloading',
          config: config,
          networkType: 'wifi',
        ),
      );

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Auto-starting download from shared link')),
      );

      setState(() => _currentIndex = 0);
    } else {
      ref.read(sharedUrlProvider.notifier).state = url;
      setState(() => _currentIndex = 0);
    }
  }

  final _screens = [
    const HomeScreen(),
    const LibraryScreen(),
    const SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final size = MediaQuery.of(context).size;
    final isWide = size.width > 600;

    if (isWide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _currentIndex,
              onDestinationSelected: (index) => setState(() => _currentIndex = index),
              backgroundColor: colorScheme.surfaceContainerLowest,
              indicatorColor: colorScheme.primaryContainer,
              selectedIconTheme: IconThemeData(color: colorScheme.onPrimaryContainer),
              unselectedIconTheme: IconThemeData(color: colorScheme.onSurfaceVariant),
              labelType: NavigationRailLabelType.all,
              selectedLabelTextStyle: TextStyle(
                fontWeight: FontWeight.bold,
                color: colorScheme.primary,
              ),
              unselectedLabelTextStyle: TextStyle(
                color: colorScheme.onSurfaceVariant,
              ),
              destinations: [
                NavigationRailDestination(
                  icon: Semantics(label: 'Download', child: Icon(Icons.download)),
                  selectedIcon: Semantics(label: 'Download', child: Icon(Icons.download)),
                  label: Text('Download'),
                ),
                NavigationRailDestination(
                  icon: Semantics(label: 'Library', child: Icon(Icons.folder_open)),
                  selectedIcon: Semantics(label: 'Library', child: Icon(Icons.folder)),
                  label: Text('Library'),
                ),
                NavigationRailDestination(
                  icon: Semantics(label: 'Settings', child: Icon(Icons.settings)),
                  selectedIcon: Semantics(label: 'Settings', child: Icon(Icons.settings)),
                  label: Text('Settings'),
                ),
              ],
            ),
            const VerticalDivider(thickness: 1, width: 1),
            Expanded(
              child: IndexedStack(
                index: _currentIndex,
                children: _screens,
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _screens,
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerLowest,
          border: Border(
            top: BorderSide(
              color: colorScheme.outlineVariant.withValues(alpha: 0.3),
            ),
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _NavItem(
                  icon: Icons.download,
                  label: 'Download',
                  isActive: _currentIndex == 0,
                  colorScheme: colorScheme,
                  onTap: () => setState(() => _currentIndex = 0),
                ),
                _NavItem(
                  icon: Icons.folder_open,
                  label: 'Library',
                  isActive: _currentIndex == 1,
                  colorScheme: colorScheme,
                  onTap: () => setState(() => _currentIndex = 1),
                ),
                _NavItem(
                  icon: Icons.settings,
                  label: 'Settings',
                  isActive: _currentIndex == 2,
                  colorScheme: colorScheme,
                  onTap: () => setState(() => _currentIndex = 2),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final ColorScheme colorScheme;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.colorScheme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    final child = isActive
        ? Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  label: label,
                  child: Icon(icon, color: colorScheme.onPrimaryContainer, size: 20),
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onPrimaryContainer,
                  ),
                ),
              ],
            ),
          )
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  label: label,
                  child: Icon(icon, color: colorScheme.onSurfaceVariant, size: 20),
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          );

    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: child,
        ),
      ),
    );
  }
}
