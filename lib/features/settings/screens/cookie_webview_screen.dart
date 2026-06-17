import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:path_provider/path_provider.dart';
import '../../../providers/settings_provider.dart';

class NetscapeCookie {
  final String domain;
  final String includeSubdomains; // 'TRUE' or 'FALSE'
  final String path;
  final String secure; // 'TRUE' or 'FALSE'
  final String expiration;
  final String name;
  final String value;
  final bool isHttpOnly;

  NetscapeCookie({
    required this.domain,
    required this.includeSubdomains,
    required this.path,
    required this.secure,
    required this.expiration,
    required this.name,
    required this.value,
    required this.isHttpOnly,
  });

  factory NetscapeCookie.fromLine(String line) {
    bool isHttpOnly = false;
    String cleanLine = line.trim();
    if (cleanLine.startsWith('#HttpOnly_')) {
      isHttpOnly = true;
      cleanLine = cleanLine.substring('#HttpOnly_'.length);
    }
    final parts = cleanLine.split('\t');
    if (parts.length < 7) {
      throw FormatException('Invalid Netscape cookie line: $line');
    }
    return NetscapeCookie(
      domain: parts[0],
      includeSubdomains: parts[1],
      path: parts[2],
      secure: parts[3],
      expiration: parts[4],
      name: parts[5],
      value: parts[6],
      isHttpOnly: isHttpOnly,
    );
  }

  String toLine() {
    final prefix = isHttpOnly ? '#HttpOnly_' : '';
    return '$prefix$domain\t$includeSubdomains\t$path\t$secure\t$expiration\t$name\t$value';
  }
}

class CookieWebViewScreen extends ConsumerStatefulWidget {
  final String loginUrl;
  final String siteName;

  const CookieWebViewScreen({
    super.key,
    required this.loginUrl,
    required this.siteName,
  });

  @override
  ConsumerState<CookieWebViewScreen> createState() => _CookieWebViewScreenState();
}

class _CookieWebViewScreenState extends ConsumerState<CookieWebViewScreen> {
  late final WebViewController _controller;
  bool _isLoading = true;
  double _progress = 0.0;
  String _currentUrl = '';
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.loginUrl;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            _currentUrl = url;
            setState(() {
              _isLoading = true;
            });
          },
          onProgress: (int progress) {
            setState(() {
              _progress = progress / 100.0;
            });
          },
          onPageFinished: (String url) async {
            setState(() {
              _isLoading = false;
            });
            _currentUrl = url;
            await _checkAndExtractCookies(url, autoClose: true);
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.loginUrl));
  }

  Future<void> _checkAndExtractCookies(String url, {required bool autoClose}) async {
    if (_isProcessing) return;
    try {
      final uri = Uri.parse(url);
      final cookieManager = WebViewCookieManager();
      final cookies = await cookieManager.platform.getCookies(uri);

      if (cookies.isEmpty) {
        if (!autoClose) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('No cookies found. Please make sure you have loaded the page.'),
              ),
            );
          }
        }
        return;
      }

      bool hasSessionToken = false;
      final lowerSite = widget.siteName.toLowerCase();
      if (lowerSite.contains('youtube') || lowerSite.contains('google')) {
        hasSessionToken = cookies.any((c) => c.name == 'SID');
      } else if (lowerSite.contains('instagram')) {
        hasSessionToken = cookies.any((c) => c.name == 'sessionid');
      } else if (lowerSite.contains('twitter') || lowerSite.contains('x')) {
        hasSessionToken = cookies.any((c) => c.name == 'auth_token');
      } else if (lowerSite.contains('bilibili')) {
        hasSessionToken = cookies.any((c) => c.name == 'SESSDATA');
      } else if (lowerSite.contains('twitch')) {
        hasSessionToken = cookies.any((c) => c.name == 'auth-token');
      }

      if (hasSessionToken || !autoClose) {
        _isProcessing = true;
        await _saveCookies(cookies);

        final notifier = ref.read(settingsProvider.notifier);
        if (lowerSite.contains('youtube')) {
          notifier.setYoutubeLoggedIn(true);
        } else if (lowerSite.contains('instagram')) {
          notifier.setInstagramLoggedIn(true);
        } else if (lowerSite.contains('twitter') || lowerSite.contains('x')) {
          notifier.setTwitterLoggedIn(true);
        } else if (lowerSite.contains('bilibili')) {
          notifier.setBilibiliLoggedIn(true);
        } else if (lowerSite.contains('twitch')) {
          notifier.setTwitchLoggedIn(true);
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Successfully authenticated for ${widget.siteName}!'),
              backgroundColor: Theme.of(context).colorScheme.primary,
            ),
          );
          Navigator.of(context).pop(true);
        }
      }
    } catch (e) {
      if (!autoClose && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error extracting cookies: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Future<void> _saveCookies(List<WebViewCookie> webViewCookies) async {
    if (webViewCookies.isEmpty) return;

    final appDir = await getApplicationDocumentsDirectory();
    final dataDir = Directory(appDir.path);
    if (!await dataDir.exists()) {
      await dataDir.create(recursive: true);
    }
    final cookiesFile = File('${dataDir.path}/cookies.txt');

    final Map<String, NetscapeCookie> cookieMap = {};

    // 1. Read existing cookies to merge
    if (await cookiesFile.exists()) {
      try {
        final lines = await cookiesFile.readAsLines();
        for (var line in lines) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || (trimmed.startsWith('#') && !trimmed.startsWith('#HttpOnly_'))) {
            continue;
          }
          try {
            final cookie = NetscapeCookie.fromLine(trimmed);
            final key = '${cookie.domain}:${cookie.name}';
            cookieMap[key] = cookie;
          } catch (_) {
            // Skip invalid or corrupt cookies
          }
        }
      } catch (_) {
        // Read errors ignored
      }
    }

    // 2. Add/update new cookies
    final nowSecs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final tenYearsSecs = nowSecs + 10 * 365 * 24 * 60 * 60;

    for (var wc in webViewCookies) {
      if (wc.name.isEmpty || wc.domain.isEmpty) continue;
      
      String domain = wc.domain;
      String includeSubdomains = domain.startsWith('.') ? 'TRUE' : 'FALSE';

      final cookie = NetscapeCookie(
        domain: domain,
        includeSubdomains: includeSubdomains,
        path: wc.path,
        secure: 'TRUE',
        expiration: tenYearsSecs.toString(),
        name: wc.name,
        value: wc.value,
        isHttpOnly: false,
      );

      final key = '${cookie.domain}:${cookie.name}';
      cookieMap[key] = cookie;
    }

    // 3. Write merged cookies back
    final buffer = StringBuffer();
    buffer.writeln('# Netscape HTTP Cookie File');
    buffer.writeln('# http://curl.haxx.se/rfc/cookie_spec.html');
    buffer.writeln('# This is a generated file!  Do not edit.');
    buffer.writeln();

    for (var cookie in cookieMap.values) {
      buffer.writeln(cookie.toLine());
    }

    await cookiesFile.writeAsString(buffer.toString());

    if (!Platform.isWindows) {
      try {
        await Process.run('chmod', ['0600', cookiesFile.path]);
      } catch (_) {
        // Ignore chmod errors on platforms where chmod is unavailable
      }
    }

    // 4. Update path in settings provider
    final notifier = ref.read(settingsProvider.notifier);
    notifier.setCookiesPath(cookiesFile.path);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.siteName,
          style: TextStyle(
            color: colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.primary,
        elevation: 0,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: TextButton(
              onPressed: () => _checkAndExtractCookies(_currentUrl, autoClose: false),
              style: TextButton.styleFrom(
                foregroundColor: colorScheme.primary,
              ),
              child: const Text(
                'Done',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
        bottom: _isLoading
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(
                  value: _progress > 0 ? _progress : null,
                  backgroundColor: colorScheme.surfaceContainerLowest,
                  color: colorScheme.primary,
                ),
              )
            : null,
      ),
      body: SafeArea(
        child: WebViewWidget(controller: _controller),
      ),
    );
  }
}
