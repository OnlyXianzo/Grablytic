import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../../../providers/settings_provider.dart';
import '../../../core/utils/app_logger.dart';
import '../../../core/utils/cookie_store.dart';
import 'cookie_webview_screen.dart';

/// Per-site cookie manager (ytdlnis-style).
///
/// One profile per site: added via WebView login or pasted cookie text.
/// Enabled profiles are merged into the single app-private `cookies.txt`
/// the engine reads — no special Android permission needed (same model as
/// ytdlnis/Seal: private dir + `0600`, backup-excluded).
class CookiesScreen extends ConsumerStatefulWidget {
  const CookiesScreen({super.key});

  @override
  ConsumerState<CookiesScreen> createState() => _CookiesScreenState();
}

class _CookiesScreenState extends ConsumerState<CookiesScreen> {
  bool _working = false;

  Future<File> _cookiesFile() async {
    final appDir = await getApplicationDocumentsDirectory();
    return File('${appDir.path}/cookies.txt');
  }

  /// Rewrite cookies.txt = existing unknown lines + enabled profiles.
  /// Unknown (legacy) lines are preserved so the error-card login flow
  /// never loses cookies when profiles regenerate the file.
  Future<void> _regenFile() async {
    final file = await _cookiesFile();
    final existing = <String>[];
    if (await file.exists()) {
      try {
        existing.addAll(await file.readAsLines());
      } catch (_) {}
    }
    final profiles = ref.read(settingsProvider).cookieProfiles;
    final enabled = profiles.where((p) => (p['enabled'] as bool? ?? true)).toList();
    final sources = <List<String>>[existing];
    for (final p in enabled) {
      final content = p['content'];
      if (content is List) {
        sources.add(content.map((e) => e.toString()).toList());
      }
    }
    await file.writeAsString(buildCookieFile(mergeCookieLines(sources)));
    if (!Platform.isWindows) {
      try {
        await Process.run('chmod', ['0600', file.path]);
      } catch (_) {}
    }
    ref.read(settingsProvider.notifier).setCookiesPath(file.path);
  }

  Future<void> _run(Future<void> Function() fn, String doneMsg) async {
    setState(() => _working = true);
    try {
      await fn();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(doneMsg)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Cookies: $e')));
      }
    }
    if (mounted) setState(() => _working = false);
  }

  Future<void> _addViaWebView() async {
    final urlCtrl = TextEditingController(text: 'https://');
    final nameCtrl = TextEditingController();
    final spec = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('New cookie login'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: urlCtrl,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Site URL',
                hintText: 'https://youtube.com',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Name (optional)',
                hintText: 'YouTube',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              final url = urlCtrl.text.trim();
              if (url.isEmpty || (!url.startsWith('http://') && !url.startsWith('https://'))) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('Enter a full URL starting with https://')),
                );
                return;
              }
              Navigator.pop(ctx, {
                'url': url,
                'name': nameCtrl.text.trim().isEmpty ? url : nameCtrl.text.trim(),
              });
            },
            child: const Text('Log in'),
          ),
        ],
      ),
    );
    if (spec == null || !mounted) return;
    final url = spec['url']!;
    final name = spec['name']!;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CookieWebViewScreen(
          loginUrl: url,
          siteName: name,
          onCaptured: (cookies) async {
            final lines = cookies.map((c) => c.toLine()).toList();
            ref.read(settingsProvider.notifier).upsertCookieProfile(
                  url: url,
                  description: name,
                  lines: lines,
                );
            await _regenFile();
            ref.read(settingsProvider.notifier).setUseCookies(true);
            AppLogger.info('Cookie profile saved for $url (${lines.length} cookies)',
                tag: 'CookiesScreen');
          },
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _addViaPaste() async {
    final urlCtrl = TextEditingController();
    final pasteCtrl = TextEditingController();
    final spec = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Paste cookies'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: urlCtrl,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Site URL',
                  hintText: 'youtube.com',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: pasteCtrl,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: 'Cookie text',
                  hintText: 'Netscape file or name=value; …',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, {
              'url': urlCtrl.text.trim(),
              'text': pasteCtrl.text,
            }),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    if (spec == null) return;
    final lines = parsePastedCookies(spec['text'] ?? '', spec['url'] ?? '');
    if (lines.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No cookies found in that text.')),
        );
      }
      return;
    }
    final url = spec['url']!.trim();
    await _run(() async {
      ref.read(settingsProvider.notifier).upsertCookieProfile(
            url: url.isEmpty ? 'pasted' : url,
            description: 'Pasted ${DateTime.now().toIso8601String().substring(0, 10)}',
            lines: lines,
          );
      await _regenFile();
      ref.read(settingsProvider.notifier).setUseCookies(true);
    }, 'Imported ${lines.length} cookies.');
  }

  Future<void> _exportClipboard() async {
    final file = await _cookiesFile();
    if (!await file.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('No cookies file yet.')));
      }
      return;
    }
    await Clipboard.setData(ClipboardData(text: await file.readAsString()));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Cookies copied to clipboard.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final profiles = settings.cookieProfiles;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cookies'),
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.primary,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.content_paste_outlined),
            tooltip: 'Paste cookies',
            onPressed: _working ? null : _addViaPaste,
          ),
          IconButton(
            icon: const Icon(Icons.copy_outlined),
            tooltip: 'Copy cookies.txt',
            onPressed: _working ? null : _exportClipboard,
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Clear all',
            onPressed: _working
                ? null
                : () => _run(() async {
                      ref.read(settingsProvider.notifier).clearCookieProfiles();
                      final file = await _cookiesFile();
                      if (await file.exists()) await file.delete();
                      ref.read(settingsProvider.notifier).setUseCookies(false);
                    }, 'All cookies cleared.'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _working ? null : _addViaWebView,
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
        icon: const Icon(Icons.add),
        label: const Text('New login'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          children: [
            SwitchListTile(
              value: settings.useCookies,
              title: const Text('Use cookies for downloads'),
              subtitle: const Text(
                'Logged-in content only. No special permission needed — '
                'cookies stay in the app\'s private folder.',
              ),
              onChanged: (v) =>
                  ref.read(settingsProvider.notifier).setUseCookies(v),
            ),
            const SizedBox(height: 8),
            if (profiles.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Column(
                  children: [
                    Icon(Icons.cookie_outlined,
                        size: 48, color: colorScheme.outline),
                    const SizedBox(height: 12),
                    Text(
                      'No cookie logins yet.\nTap “New login” to sign in on a site,\nor paste cookies from another app.',
                      textAlign: TextAlign.center,
                      style: textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              )
            else
              for (final p in profiles)
                Card(
                  child: SwitchListTile(
                    value: (p['enabled'] as bool? ?? true),
                    title: Text((p['description'] as String?)?.isNotEmpty == true
                        ? p['description'] as String
                        : (p['url'] as String? ?? 'Cookie login')),
                    subtitle: Text(
                      '${((p['content'] as List?)?.length ?? 0)} cookies · ${p['url'] ?? ''}',
                    ),
                    secondary: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Delete',
                      onPressed: _working
                          ? null
                          : () => _run(() async {
                                ref
                                    .read(settingsProvider.notifier)
                                    .deleteCookieProfile(p['id'] as String);
                                await _regenFile();
                              }, 'Cookie login deleted.'),
                    ),
                    onChanged: (_) => _run(() async {
                      ref
                          .read(settingsProvider.notifier)
                          .toggleCookieProfile(p['id'] as String);
                      await _regenFile();
                    }, 'Saved.'),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
