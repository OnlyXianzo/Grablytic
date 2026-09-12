import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../../providers/settings_provider.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  int _beat = 1;

  void _nextBeat() {
    if (_beat < 4) {
      setState(() => _beat++);
    }
  }

  void _complete() {
    ref.read(settingsProvider.notifier).completeOnboarding();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Ambient stars/dots background for Beat 1, 2 & 3
          if (_beat <= 3)
            Positioned.fill(
              child: Opacity(
                opacity: 0.1,
                child: CustomPaint(
                  painter: _ParticlesPainter(),
                ),
              ),
            ),

          // Content Layer based on active beat
          Positioned.fill(
            child: Semantics(
              label: _beat < 4 ? 'Tap to continue' : '',
              button: _beat < 4,
              excludeSemantics: _beat >= 4,
              child: GestureDetector(
                onTap: (_beat < 4) ? _nextBeat : null,
                behavior: HitTestBehavior.opaque,
                child: SafeArea(
                  child: AnimatedSwitcher(
                    duration: 600.ms,
                    switchInCurve: Curves.easeInOutCubic,
                    switchOutCurve: Curves.easeInOutCubic,
                    child: _buildBeatContent(context, colorScheme, textTheme),
                  ),
                ),
              ),
            ),
          ),

          // Skip Button
          if (_beat < 4)
            Positioned(
              top: 16,
              right: 16,
              child: TextButton(
                onPressed: _complete,
                child: Text(
                  'Skip',
                  style: textTheme.bodyMedium?.copyWith(
                    color: Colors.white70,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),

          // Tap anywhere hint for beats 1, 2 & 3
          if (_beat < 4)
            Positioned(
              bottom: 48,
              left: 0,
              right: 0,
              child: Center(
                child: Text(
                  'Tap anywhere to continue',
                  style: textTheme.bodyMedium?.copyWith(
                    color: Colors.white38,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ).animate(onComplete: (c) => c.repeat(reverse: true))
                  .fadeIn(duration: 600.ms)
                  .then(delay: 1200.ms)
                  .fadeOut(duration: 600.ms),
            ),
        ],
      ),
    );
  }

  Widget _buildBeatContent(
    BuildContext context,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    switch (_beat) {
      case 1:
        return Column(
          key: const ValueKey(1),
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ClipOval(
              child: Image.asset(
                'assets/brand/truestream_logo.png',
                width: 96,
                height: 96,
                fit: BoxFit.cover,
              ),
            )
                .animate()
                .scale(begin: const Offset(0.8, 0.8), curve: Curves.easeOutBack, duration: 800.ms)
                .fadeIn(duration: 800.ms),
            const SizedBox(height: 24),
            Text(
              'TrueStream',
              style: textTheme.displayLarge?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w300,
              ),
            )
                .animate()
                .slideY(begin: 0.3, curve: Curves.easeOutCubic, duration: 800.ms)
                .fadeIn(duration: 800.ms),
            const SizedBox(height: 16),
            Text(
              'Every source. Maximum quality.',
              style: textTheme.bodyLarge?.copyWith(
                color: Colors.white70,
                fontStyle: FontStyle.italic,
              ),
            )
                .animate(delay: 400.ms)
                .fadeIn(duration: 600.ms),
          ],
        );
      case 2:
        return Column(
          key: const ValueKey(2),
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '1,000+ sources',
              style: textTheme.displayLarge?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w300,
              ),
            )
                .animate()
                .scale(begin: const Offset(0.8, 0.8), curve: Curves.easeOutBack, duration: 800.ms)
                .fadeIn(duration: 800.ms),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildSourceBadge('YouTube'),
                const SizedBox(width: 8),
                _buildSourceBadge('SoundCloud'),
                const SizedBox(width: 8),
                _buildSourceBadge('Instagram'),
              ],
            ).animate(delay: 300.ms).fadeIn().slideY(begin: 0.2),
          ],
        );
      case 3:
        return Padding(
          key: const ValueKey(3),
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Self-Contained Power',
                style: textTheme.headlineMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ).animate().fadeIn(),
              const SizedBox(height: 8),
              Text(
                'Why is the app size 100+ MB?',
                style: textTheme.titleMedium?.copyWith(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ).animate(delay: 200.ms).fadeIn(),
              const SizedBox(height: 24),
              _buildFeatureCard(
                title: 'Embedded Python & yt-dlp',
                subtitle: 'Houses a sandboxed Python 3.11 environment to decrypt Google/Instagram signatures directly on-device.',
                icon: Icons.code,
                colorScheme: colorScheme,
                textTheme: textTheme,
              ).animate(delay: 400.ms).slideY(begin: 0.2, curve: Curves.easeOutCubic, duration: 400.ms).fadeIn(),
              const SizedBox(height: 16),
              _buildFeatureCard(
                title: 'Bundled Static FFmpeg',
                subtitle: 'Embeds post-processing binaries to merge separate high-bitrate video & audio streams on-device.',
                icon: Icons.settings_input_component,
                colorScheme: colorScheme,
                textTheme: textTheme,
              ).animate(delay: 800.ms).slideY(begin: 0.2, curve: Curves.easeOutCubic, duration: 400.ms).fadeIn(),
              const SizedBox(height: 20),
              Text(
                'No external apps required. Absolute maximum quality, processed locally.',
                style: textTheme.bodyMedium?.copyWith(
                  color: Colors.white70,
                  fontStyle: FontStyle.italic,
                ),
                textAlign: TextAlign.center,
              ).animate(delay: 1000.ms).fadeIn(),
            ],
          ),
        );
      case 4:
        return Padding(
          key: const ValueKey(4),
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildFeatureCard(
                title: '4K AV1. No compromise.',
                subtitle: 'Downloads the absolute highest fidelity available.',
                icon: Icons.high_quality,
                colorScheme: colorScheme,
                textTheme: textTheme,
              ).animate().slideX(begin: 0.5, curve: Curves.easeOutCubic, duration: 400.ms).fadeIn(),
              const SizedBox(height: 16),
              _buildFeatureCard(
                title: 'Zero throttle. Full speed.',
                subtitle: '16 parallel connections bypass client-side limits.',
                icon: Icons.speed,
                colorScheme: colorScheme,
                textTheme: textTheme,
              ).animate(delay: 400.ms).slideX(begin: 0.5, curve: Curves.easeOutCubic, duration: 400.ms).fadeIn(),
              const SizedBox(height: 16),
              _buildFeatureCard(
                title: 'No ads. No account.',
                subtitle: 'Fully anonymous and secure media acquisition.',
                icon: Icons.lock_outline,
                colorScheme: colorScheme,
                textTheme: textTheme,
              ).animate(delay: 800.ms).slideX(begin: 0.5, curve: Curves.easeOutCubic, duration: 400.ms).fadeIn(),
              const SizedBox(height: 40),
              ElevatedButton(
                onPressed: _complete,
                style: ElevatedButton.styleFrom(
                  backgroundColor: colorScheme.primaryContainer,
                  foregroundColor: colorScheme.onPrimaryContainer,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('Get Started'),
              ).animate().fadeIn(delay: 800.ms),
            ],
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildSourceBadge(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white12,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white24),
      ),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _buildFeatureCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required ColorScheme colorScheme,
    required TextTheme textTheme,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        children: [
          Semantics(
            label: title,
            child: Icon(icon, color: Colors.white, size: 32),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: textTheme.bodyMedium?.copyWith(
                    color: Colors.white70,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ParticlesPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white24;
    canvas.drawCircle(Offset(size.width * 0.2, size.height * 0.3), 2, paint);
    canvas.drawCircle(Offset(size.width * 0.8, size.height * 0.15), 1.5, paint);
    canvas.drawCircle(Offset(size.width * 0.45, size.height * 0.75), 3, paint);
    canvas.drawCircle(Offset(size.width * 0.15, size.height * 0.65), 1.2, paint);
    canvas.drawCircle(Offset(size.width * 0.7, size.height * 0.8), 2.5, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
