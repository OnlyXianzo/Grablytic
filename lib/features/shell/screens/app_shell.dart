import 'dart:async';
import 'dart:collection';
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
import '../../../providers/metered_guard.dart';
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
  // T2-6: FIFO of share URLs awaiting a sheet. A second share arriving
  // while a sheet is open used to be silently dropped (single-var native
  // slot + open-guard with no backlog). Bounded like the native side.
  final ListQueue<String> _pendingShareUrls = ListQueue();
  static const int _maxPendingShares = 50;
  bool _sharePumping = false;
  // Exactly-once drain guard: the native push is a wake-up hint only, so
  // concurrent hints (cold-start + stream for one share) coalesce into a
  // single queue drain instead of double-enqueueing the same URL.
  bool _drainingShares = false;
  bool _needsRedrain = false;

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
    // The native intent/shared_url push is a WAKE-UP HINT only (the queue
    // is the single source of truth). Drain via get_shared so one native
    // enqueue yields exactly one sheet — the old code enqueued the hint
    // payload directly AND drained the same URL, showing "choose quality"
    // twice for a single Instagram share.
    _intentSubscription = engine.sharedUrlStream.listen((_) {
      _drainNativeQueue();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _drainNativeQueue();
      _checkBatteryPrompt();
    });
  }

  /// Pops every queued native share (exactly-once via poll) into the Dart
  /// FIFO. Concurrent hints coalesce: a second hint while a drain is in
  /// flight just re-drains afterwards instead of duplicating.
  Future<void> _drainNativeQueue() async {
    if (!mounted) return;
    if (_drainingShares) {
      _needsRedrain = true;
      return;
    }
    _drainingShares = true;
    try {
      final engine = ref.read(engineProvider);
      for (var i = 0; i < _maxPendingShares; i++) {
        final sharedUrl = await engine.getSharedUrl();
        if (sharedUrl == null || sharedUrl.isEmpty) break;
        _enqueueSharedUrl(sharedUrl);
      }
    } finally {
      _drainingShares = false;
    }
    if (_needsRedrain && mounted) {
      _needsRedrain = false;
      await _drainNativeQueue();
    }
  }

  /// Enqueue a share URL and drive the sheet pump. Each URL is consumed
  /// exactly once, in arrival order; overflow evicts the oldest.
  void _enqueueSharedUrl(String url) {
    if (url.isEmpty || !mounted) return;
    if (_pendingShareUrls.length >= _maxPendingShares) {
      _pendingShareUrls.removeFirst();
    }
    _pendingShareUrls.addLast(url);
    _pumpShareQueue();
  }

  Future<void> _pumpShareQueue() async {
    if (_sharePumping || _shareSheetOpen) return;
    if (_pendingShareUrls.isEmpty || !mounted) return;
    _sharePumping = true;
    try {
      await _handleSharedUrl(_pendingShareUrls.removeFirst());
    } finally {
      _sharePumping = false;
    }
    // Chain consecutive auto-starts (no sheet opened to chain off).
    if (mounted && !_shareSheetOpen) _pumpShareQueue();
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
    final isAuto =
        settings.shareBehavior == 'auto' || settings.autoStartDownloadOnShare;
    if (isAuto) {
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
            content: Text(
              'Engine still setting up — review the link, then retry.',
            ),
          ),
        );
        return;
      }
      if (!isWithinScheduleWindow(settings, DateTime.now()) && mounted) {
        final go = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
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
      // Metered gate (Seal parity): the auto-start share path fires
      // without further taps — confirm on metered links like any tap.
      if (mounted &&
          !await ensureUnmeteredDownload(context: context, ref: ref)) {
        _currentIndex = 0;
        _pageController.jumpToPage(0);
        return;
      }
      if (!mounted) return;
      final notifier = ref.read(downloadProvider.notifier);
      if (notifier.isDownloading(url)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Download already in progress for this link'),
          ),
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

      try {
        final startRes = await ref
            .read(engineProvider)
            .startDownload(
              url: url,
              downloadId: downloadId,
              config: config,
              networkType: 'wifi',
            );

        if (startRes['success'] == true) {
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
              content: Text(
                startRes['queued'] == true
                    ? 'Queued — starts when a slot frees up'
                    : 'Auto-starting download from shared link',
              ),
            ),
          );
        } else {
          final errorMsg =
              startRes['error_message'] as String? ??
              'Could not start download';
          await ref
              .read(engineProvider)
              .showErrorNotification(
                downloadId: downloadId,
                title: 'Download failed',
                error: errorMsg,
              );
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Auto-download failed: $errorMsg')),
          );
        }
      } catch (e) {
        AppLogger.error('Auto-start download failed: $e', tag: 'AppShell');
        await ref
            .read(engineProvider)
            .showErrorNotification(
              downloadId: downloadId,
              title: 'Download failed',
              error: e.toString(),
            );
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Auto-download failed: $e')));
      }

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
      // A share that arrived while this sheet was open goes next.
      _pumpShareQueue();
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
    AppLogger.info(
      'User swiped to tab: $index (${_screens[index].runtimeType})',
    );
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
    // T16: the indicator bar drives the controller itself on drag-settle;
    // taps still animate here (jump under reduced motion).
    try {
      final cur = _pageController.hasClients ? _pageController.page : null;
      if (cur != null && (cur - index).abs() <= 0.02) return;
    } catch (_) {}
    final noAnim = WidgetsBinding
        .instance
        .platformDispatcher
        .accessibilityFeatures
        .reduceMotion;
    if (noAnim) {
      try {
        _pageController.jumpToPage(index);
      } catch (_) {}
    } else {
      _pageController.animateToPage(
        index,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  /// T16: drag release already animated the controller in the bar — record
  /// the index (fly-through guard in [_onPageChanged] handles the rest).
  void _onIndicatorSettled(int index) {
    if (index == _currentIndex) {
      _animTarget = null;
      return;
    }
    AppLogger.info('Indicator settled to tab: $index');
    setState(() {
      _currentIndex = index;
    });
    _animTarget = index;
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
              selectedIconTheme: IconThemeData(
                color: colorScheme.onPrimaryContainer,
              ),
              unselectedIconTheme: IconThemeData(
                color: colorScheme.onSurfaceVariant,
              ),
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
                  icon: Semantics(
                    label: 'Download',
                    child: Icon(Icons.download),
                  ),
                  selectedIcon: Semantics(
                    label: 'Download',
                    child: Icon(Icons.download),
                  ),
                  label: Text('Download'),
                ),
                NavigationRailDestination(
                  icon: Semantics(
                    label: 'Library',
                    child: Icon(Icons.folder_open),
                  ),
                  selectedIcon: Semantics(
                    label: 'Library',
                    child: Icon(Icons.folder),
                  ),
                  label: Text('Library'),
                ),
                NavigationRailDestination(
                  icon: Semantics(
                    label: 'Settings',
                    child: Icon(Icons.settings),
                  ),
                  selectedIcon: Semantics(
                    label: 'Settings',
                    child: Icon(Icons.settings),
                  ),
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
        onIndicatorSettled: _onIndicatorSettled,
        colorScheme: colorScheme,
        pageController: _pageController,
      ),
    );
  }
}

class _NavItemData {
  final IconData icon;
  final String label;

  const _NavItemData({required this.icon, required this.label});
}

class _FluidBottomNavBar extends StatefulWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final ValueChanged<int> onIndicatorSettled;
  final ColorScheme colorScheme;
  final PageController pageController;

  const _FluidBottomNavBar({
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.onIndicatorSettled,
    required this.colorScheme,
    required this.pageController,
  });

  @override
  State<_FluidBottomNavBar> createState() => _FluidBottomNavBarState();
}

class _FluidBottomNavBarState extends State<_FluidBottomNavBar> {
  // T16: the PageController is the single source of truth. Position flows
  // controller → _pos → AnimatedBuilder with zero per-frame setState calls.
  final ValueNotifier<double> _pos = ValueNotifier(0.0);

  static const List<_NavItemData> _items = [
    _NavItemData(icon: Icons.download, label: 'Download'),
    _NavItemData(icon: Icons.folder_open, label: 'Library'),
    _NavItemData(icon: Icons.settings, label: 'Settings'),
  ];

  double _readPos() {
    try {
      if (widget.pageController.hasClients) {
        final p = widget.pageController.page;
        if (p != null) {
          return p.clamp(0.0, (_items.length - 1).toDouble());
        }
      }
    } catch (_) {}
    return widget.selectedIndex.toDouble();
  }

  double get _viewport {
    try {
      if (widget.pageController.hasClients) {
        return widget.pageController.position.viewportDimension;
      }
    } catch (_) {}
    return 0.0;
  }

  @override
  void initState() {
    super.initState();
    _pos.value = widget.selectedIndex.toDouble();
    widget.pageController.addListener(_onPage);
  }

  @override
  void didUpdateWidget(covariant _FluidBottomNavBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.pageController, oldWidget.pageController)) {
      oldWidget.pageController.removeListener(_onPage);
      widget.pageController.addListener(_onPage);
    }
    // Nothing else: taps/swipes animate the controller in the parent and
    // this bar follows it; drags below drive the controller directly.
  }

  @override
  void dispose() {
    widget.pageController.removeListener(_onPage);
    _pos.dispose();
    super.dispose();
  }

  void _onPage() {
    _pos.value = _readPos();
  }

  /// Reduced-motion gate for the settle animation.
  ///
  /// Android "Remove animations" arrives via [MediaQuery.disableAnimations],
  /// but iOS Reduce Motion does NOT set that flag — it surfaces separately
  /// via [AccessibilityFeatures.reduceMotion]. Either one means: jump the
  /// highlight instantly instead of sliding it.
  bool _animationsDisabled(BuildContext context) {
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) return true;
    return WidgetsBinding
        .instance
        .platformDispatcher
        .accessibilityFeatures
        .reduceMotion;
  }

  /// Drag scrubs pages 1:1 through the controller (the pill follows via
  /// the listener above).
  void _scrubTo(double localX, double barWidth) {
    final vp = _viewport;
    if (vp <= 0) return;
    final slot = barWidth / _items.length;
    final target = ((localX / slot) - 0.5).clamp(
      0.0,
      (_items.length - 1).toDouble(),
    );
    widget.pageController.jumpTo(target * vp);
  }

  /// Release settles to the nearest page; fast flings carry one extra page.
  /// Duration scales with fling velocity (120–350 ms). The parent only
  /// records the index — it must not re-animate (the bar already did).
  void _settle(double velocityPxPerSec, BuildContext context) {
    final vp = _viewport;
    final page = _pos.value;
    var target = page.round();
    if (vp > 0) {
      final vPages = velocityPxPerSec / vp;
      if (vPages.abs() > 1.5) {
        target = (page + (vPages > 0 ? 0.5 : -0.5)).round();
      }
    }
    target = target.clamp(0, _items.length - 1);
    final distance = (target - page).abs();
    if (distance <= 0.001 || vp <= 0) {
      widget.onIndicatorSettled(target);
      return;
    }
    var ms = 320;
    final vAbs = (velocityPxPerSec / vp).abs();
    if (vAbs > 0.01) {
      ms = (distance / vAbs * 1000).round().clamp(120, 350);
    }
    if (_animationsDisabled(context)) {
      widget.pageController.jumpTo(target * vp);
    } else {
      widget.pageController.animateTo(
        target * vp,
        duration: Duration(milliseconds: ms),
        curve: Curves.easeOut,
      );
    }
    widget.onIndicatorSettled(target);
  }

  void _cancelBack(BuildContext context) {
    final target = widget.selectedIndex;
    final vp = _viewport;
    if (vp > 0 && !_animationsDisabled(context)) {
      widget.pageController.animateTo(
        target * vp,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    } else if (vp > 0) {
      widget.pageController.jumpTo(target * vp);
    }
    widget.onIndicatorSettled(target);
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    // T16: one AnimatedBuilder on controller-driven notifiers — the pill,
    // colors, and stretch all derive from the fractional page, never from
    // per-frame setState.
    return AnimatedBuilder(
      animation: _pos,
      builder: (context, _) {
        final currentPos = _pos.value;
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

                  // Liquid morph from the fractional page offset: the
                  // highlight stretches mid-transition, equally for taps,
                  // swipes, and indicator drags (all flow through the
                  // controller now).
                  final distFromInt = (currentPos - currentPos.round()).abs();
                  final stretchFactor = (distFromInt * 0.22).clamp(0.0, 0.35);
                  final squishFactor = (distFromInt * 0.06).clamp(0.0, 0.1);

                  const baseHeight = 44.0;
                  final baseWidth = math.min(slotWidth - 8.0, 96.0);
                  final pillWidth = baseWidth * (1.0 + stretchFactor);
                  final pillHeight = baseHeight * (1.0 - squishFactor);

                  final centerX = (currentPos + 0.5) * slotWidth;
                  final pillLeft = (centerX - (pillWidth / 2)).clamp(
                    0.0,
                    totalWidth - pillWidth,
                  );
                  const containerHeight = 56.0;
                  final pillTop = (containerHeight - pillHeight) / 2;

                  return GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onHorizontalDragStart: (details) {
                      _scrubTo(details.localPosition.dx, totalWidth);
                    },
                    onHorizontalDragUpdate: (details) {
                      _scrubTo(details.localPosition.dx, totalWidth);
                    },
                    onHorizontalDragEnd: (details) {
                      _settle(details.primaryVelocity ?? 0.0, context);
                    },
                    onHorizontalDragCancel: () => _cancelBack(context),
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
                                borderRadius: BorderRadius.circular(
                                  pillHeight / 2,
                                ),
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
                              final dist = (index - currentPos).abs().clamp(
                                0.0,
                                1.0,
                              );
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
                                    onTap: () =>
                                        widget.onDestinationSelected(index),
                                    containedInkWell: true,
                                    highlightShape: BoxShape.rectangle,
                                    borderRadius: BorderRadius.circular(24),
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        minWidth: 48,
                                        minHeight: 48,
                                      ),
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
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
                                            style: textTheme.labelSmall
                                                ?.copyWith(
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
      },
    );
  }
}
