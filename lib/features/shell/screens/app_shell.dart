import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../home/screens/home_screen.dart';
import '../../home/widgets/share_intent_sheet.dart';
import '../../library/screens/library_screen.dart';
import '../../settings/screens/settings_screen.dart';
import '../../../providers/download_provider.dart';
import '../../../providers/engine_status_provider.dart';
import '../../../providers/settings_provider.dart';
import '../../../core/engine/engine_provider.dart';
import '../../../core/utils/app_logger.dart';
import '../../../core/utils/download_config.dart';
import '../../../core/utils/schedule_guard.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int _currentIndex = 0;
  late final PageController _pageController;
  StreamSubscription<String>? _intentSubscription;
  // Target of a programmatic tab animation. PageView fires onPageChanged
  // for every fly-through page (0→2 emits 1, then 2) — non-target pages
  // are ignored so logs/state update exactly once. User drags leave this
  // null and behave as before.
  int? _animTarget;
  // Guards against stacking duplicate share sheets when intents arrive in
  // quick succession (cold-start getSharedUrl + stream event for one share).
  bool _shareSheetOpen = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _currentIndex);
    _initSharedUrlListening();
  }

  @override
  void dispose() {
    _intentSubscription?.cancel();
    _pageController.dispose();
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
      _checkBatteryPrompt();
    });
  }

  Future<void> _checkBatteryPrompt() async {
    if (!Platform.isAndroid || !mounted) return;
    final settings = ref.read(settingsProvider);
    if (settings.hasSeenBatteryPrompt) return;

    final engine = ref.read(engineProvider);
    final status = await engine.batteryExemptionStatus();
    if (status['exempt'] == true) {
      ref.read(settingsProvider.notifier).setHasSeenBatteryPrompt(true);
      return;
    }

    if (!mounted) return;
    final res = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Background Downloads'),
        content: const Text(
          'Allow Grablytic to run unrestricted in the background so downloads do not pause or fail when your screen is turned off.\n\nYou can also configure this later in Settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Skip'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Enable'),
          ),
        ],
      ),
    );

    ref.read(settingsProvider.notifier).setHasSeenBatteryPrompt(true);
    if (res == true && mounted) {
      await engine.requestBatteryExemption();
    }
  }

  Future<void> _handleSharedUrl(String url) async {
    if (url.isEmpty || !mounted) return;

    final settings = ref.read(settingsProvider);
    if (settings.autoStartDownloadOnShare) {
      // Engine-readiness gate: never auto-start into an unbootstrapped
      // engine (empty/failed download). Fall back to the preview sheet path
      // so the user sees a "still setting up" state instead of silence.
      EngineStatus status;
      try {
        status = await ref.read(engineStatusProvider.future);
      } catch (e) {
        status = EngineStatus(ready: false, error: e.toString());
      }
      if (!mounted) return;
      if (!status.ready) {
        ref.read(sharedUrlProvider.notifier).state = url;
        _currentIndex = 0;
        _pageController.jumpToPage(0);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Engine still setting up — review the link, then retry.'),
          ),
        );
        return;
      }
      if (!isWithinScheduleWindow(settings, DateTime.now()) && mounted) {
        final go = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text('Outside scheduled window'),
            content: Text(
              'Your download schedule is ${scheduleSummary(settings)}.\n\n'
              'Auto-start this shared download now anyway?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Wait'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Start anyway'),
              ),
            ],
          ),
        );
        if (!mounted || !(go ?? false)) {
          _currentIndex = 0;
          _pageController.jumpToPage(0);
          return;
        }
      }
      final notifier = ref.read(downloadProvider.notifier);
      if (notifier.isDownloading(url)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Download already in progress for this link')),
        );
        _currentIndex = 0;
        _pageController.jumpToPage(0);
        return;
      }

      final downloadId = const Uuid().v4();
      final config = <String, dynamic>{
        'container': settings.qualityCeiling == 'best' ? 'mkv' : 'mp4',
        'quality_ceiling': settings.qualityCeiling,
        'audio_only': settings.audioOnly,
        ...settingsDownloadConfig(settings),
      };

      final startRes = await ref.read(engineProvider).startDownload(
        url: url,
        downloadId: downloadId,
        config: config,
        networkType: 'wifi',
      );

      notifier.addDownload(
        DownloadItem(
          id: downloadId,
          title: url,
          url: url,
          status: startRes['queued'] == true ? 'queued' : 'downloading',
          config: config,
          networkType: 'wifi',
        ),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(startRes['queued'] == true
                ? 'Queued — starts when a slot frees up'
                : 'Auto-starting download from shared link')),
      );

      _currentIndex = 0;
      _pageController.jumpToPage(0);
    } else {
      // Default path: prefill the Home URL field (existing behavior, kept
      // for continuity) AND surface the share bottom sheet so the user
      // picks quality/settings before anything downloads.
      ref.read(sharedUrlProvider.notifier).state = url;
      _currentIndex = 0;
      _pageController.jumpToPage(0);
      _showShareSheet(url);
    }
  }

  /// Share bottom sheet (YTDLnis/Seal "bottom card" parity at the Dart
  /// layer). Instant and lightweight: format extraction stays deferred to
  /// FormatPickerScreen after the user confirms.
  void _showShareSheet(String url) {
    if (!mounted || _shareSheetOpen) return;
    _shareSheetOpen = true;
    showShareIntentSheet<void>(context, url).whenComplete(() {
      _shareSheetOpen = false;
    });
  }

  final _screens = [
    const HomeScreen(),
    const LibraryScreen(),
    const SettingsScreen(),
  ];

  void _onPageChanged(int index) {
    if (_animTarget != null) {
      if (index != _animTarget) return; // fly-through page: ignore
      _animTarget = null; // settled; _currentIndex already equals target
      return;
    }
    if (index == _currentIndex) return;
    AppLogger.info('User swiped to tab: $index (${_screens[index].runtimeType})');
    setState(() {
      _currentIndex = index;
    });
  }

  /// User grabbed the pager mid-animation → the programmatic target is
  /// void; subsequent onPageChanged calls are genuine user swipes again.
  /// (Programmatic animateToPage emits ScrollStartNotification with null
  /// dragDetails, so only real touches clear the flag.)
  bool _onScrollNotify(ScrollNotification n) {
    if (n is ScrollStartNotification && n.dragDetails != null) {
      _animTarget = null;
    }
    return false;
  }

  void _onDestinationSelected(int index) {
    if (index == _currentIndex) return;
    AppLogger.info('User clicked tab navigation from $_currentIndex to $index');
    setState(() {
      _currentIndex = index;
    });
    _animTarget = index;
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

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
              onDestinationSelected: _onDestinationSelected,
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
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScrollNotify,
                child: PageView(
                  controller: _pageController,
                  onPageChanged: _onPageChanged,
                  children: _screens,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      body: NotificationListener<ScrollNotification>(
        onNotification: _onScrollNotify,
        child: PageView(
          controller: _pageController,
          onPageChanged: _onPageChanged,
          children: _screens,
        ),
      ),
      bottomNavigationBar: _FluidBottomNavBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: _onDestinationSelected,
        colorScheme: colorScheme,
      ),
    );
  }
}

class _NavItemData {
  final IconData icon;
  final String label;

  const _NavItemData({
    required this.icon,
    required this.label,
  });
}

class _FluidBottomNavBar extends StatefulWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final ColorScheme colorScheme;

  const _FluidBottomNavBar({
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.colorScheme,
  });

  @override
  State<_FluidBottomNavBar> createState() => _FluidBottomNavBarState();
}

class _FluidBottomNavBarState extends State<_FluidBottomNavBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _morphController;
  late Animation<double> _posAnim;

  double _currentPos = 0.0;
  double _animStartPos = 0.0;
  double _animTargetPos = 0.0;
  bool _isDragging = false;

  static const List<_NavItemData> _items = [
    _NavItemData(icon: Icons.download, label: 'Download'),
    _NavItemData(icon: Icons.folder_open, label: 'Library'),
    _NavItemData(icon: Icons.settings, label: 'Settings'),
  ];

  @override
  void initState() {
    super.initState();
    _currentPos = widget.selectedIndex.toDouble();
    _animStartPos = _currentPos;
    _animTargetPos = _currentPos;
    _morphController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _posAnim = AlwaysStoppedAnimation(_currentPos);
  }

  @override
  void dispose() {
    _morphController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _FluidBottomNavBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedIndex != oldWidget.selectedIndex && !_isDragging) {
      final target = widget.selectedIndex.toDouble();
      _animateTo(target, immediate: _animationsDisabled(context));
    }
  }

  /// Reduced-motion gate for the pill animation.
  ///
  /// Android "Remove animations" arrives via [MediaQuery.disableAnimations],
  /// but iOS Reduce Motion does NOT set that flag — it surfaces separately
  /// via [AccessibilityFeatures.reduceMotion]. Either one means: jump the
  /// highlight instantly instead of sliding it.
  bool _animationsDisabled(BuildContext context) {
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) return true;
    return WidgetsBinding
        .instance.platformDispatcher.accessibilityFeatures.reduceMotion;
  }

  void _animateTo(double target, {bool immediate = false}) {
    if (immediate) {
      _morphController.stop();
      setState(() {
        _currentPos = target;
        _animStartPos = target;
        _animTargetPos = target;
      });
      return;
    }

    _animStartPos = _currentPos;
    _animTargetPos = target;
    _morphController.stop();
    _morphController.reset();

    _posAnim = Tween<double>(begin: _animStartPos, end: _animTargetPos).animate(
      CurvedAnimation(
        parent: _morphController,
        curve: Curves.easeInOutCubic,
      ),
    )..addListener(() {
        setState(() {
          _currentPos = _posAnim.value;
        });
      });

    _morphController.forward();
  }

  void _handleDrag(double localX, double totalWidth) {
    final slotWidth = totalWidth / _items.length;
    final pos = ((localX / slotWidth) - 0.5).clamp(0.0, (_items.length - 1).toDouble());
    setState(() {
      _currentPos = pos;
    });
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Container(
      decoration: BoxDecoration(
        color: widget.colorScheme.surfaceContainerLowest,
        border: Border(
          top: BorderSide(
            color: widget.colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final totalWidth = constraints.maxWidth;
              final slotWidth = totalWidth / _items.length;

              // Fluid / liquid morph calculations:
              // During transition, the highlight stretches horizontally and slightly
              // compresses vertically, mimicking liquid surface tension and volume preservation.
              double stretchFactor = 0.0;
              double squishFactor = 0.0;

              if (_morphController.isAnimating) {
                final animProgress = _morphController.value;
                final morphFactor = math.sin(animProgress * math.pi);
                final travelDist = (_animTargetPos - _animStartPos).abs();
                stretchFactor = (morphFactor * 0.28 * travelDist).clamp(0.0, 0.45);
                squishFactor = (morphFactor * 0.08).clamp(0.0, 0.15);
              } else if (_isDragging) {
                final distFromInt = (_currentPos - _currentPos.round()).abs();
                stretchFactor = (distFromInt * 0.22).clamp(0.0, 0.35);
                squishFactor = (distFromInt * 0.06).clamp(0.0, 0.1);
              }

              const baseHeight = 44.0;
              final baseWidth = math.min(slotWidth - 8.0, 96.0);
              final pillWidth = baseWidth * (1.0 + stretchFactor);
              final pillHeight = baseHeight * (1.0 - squishFactor);

              final centerX = (_currentPos + 0.5) * slotWidth;
              final pillLeft = (centerX - (pillWidth / 2)).clamp(0.0, totalWidth - pillWidth);
              const containerHeight = 56.0;
              final pillTop = (containerHeight - pillHeight) / 2;

              return GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragStart: (details) {
                  _isDragging = true;
                  _morphController.stop();
                  _handleDrag(details.localPosition.dx, totalWidth);
                },
                onHorizontalDragUpdate: (details) {
                  _handleDrag(details.localPosition.dx, totalWidth);
                },
                onHorizontalDragEnd: (details) {
                  _isDragging = false;
                  final target = _currentPos.round().clamp(0, _items.length - 1);
                  _animateTo(target.toDouble(),
                      immediate: _animationsDisabled(context));
                  widget.onDestinationSelected(target);
                },
                onHorizontalDragCancel: () {
                  _isDragging = false;
                  final target = widget.selectedIndex.toDouble();
                  _animateTo(target,
                      immediate: _animationsDisabled(context));
                },
                child: SizedBox(
                  height: containerHeight,
                  width: totalWidth,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // Smoothly sliding and morphing liquid pill highlight
                      Positioned(
                        left: pillLeft,
                        top: pillTop,
                        width: pillWidth,
                        height: pillHeight,
                        child: Container(
                          decoration: BoxDecoration(
                            color: widget.colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(pillHeight / 2),
                          ),
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 3),
                              width: 16 * (1.0 + stretchFactor),
                              height: 2.5,
                              decoration: BoxDecoration(
                                color: widget.colorScheme.primary,
                                borderRadius: BorderRadius.circular(1.25),
                              ),
                            ),
                          ),
                        ),
                      ),
                      // Navigation items
                      Row(
                        children: List.generate(_items.length, (index) {
                          final item = _items[index];
                          final dist = (index - _currentPos).abs().clamp(0.0, 1.0);
                          final activeWeight = 1.0 - dist;

                          final iconColor = Color.lerp(
                            widget.colorScheme.onSurfaceVariant,
                            widget.colorScheme.onPrimaryContainer,
                            activeWeight,
                          )!;
                          final textColor = Color.lerp(
                            widget.colorScheme.onSurfaceVariant,
                            widget.colorScheme.onPrimaryContainer,
                            activeWeight,
                          )!;

                          final isSelected = widget.selectedIndex == index;

                          return Expanded(
                            child: Semantics(
                              button: true,
                              selected: isSelected,
                              label: item.label,
                              child: InkResponse(
                                onTap: () => widget.onDestinationSelected(index),
                                containedInkWell: true,
                                highlightShape: BoxShape.rectangle,
                                borderRadius: BorderRadius.circular(24),
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    minWidth: 48,
                                    minHeight: 48,
                                  ),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        item.icon,
                                        size: 22,
                                        color: iconColor,
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        item.label,
                                        style: textTheme.labelSmall?.copyWith(
                                          fontWeight: activeWeight > 0.5
                                              ? FontWeight.bold
                                              : FontWeight.w600,
                                          color: textColor,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        }),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
