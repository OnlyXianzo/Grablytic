import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Migration-aware download-folder resolution (TrueStream → Grablytic).
///
/// - Fresh installs get `<parent>/Grablytic` (created on demand).
/// - If a legacy `<parent>/TrueStream` folder already exists (and no
///   `Grablytic` folder does), it keeps being used so the rename never
///   orphans the user's existing files. Nothing is moved, renamed, or
///   deleted — the user can switch folders at any time in Settings, and an
///   explicitly stored `downloadPath` always wins over both defaults.
Future<String> _resolveDownloadDir(Directory parent) async {
  final next = Directory('${parent.path}/Grablytic');
  if (await next.exists()) return next.path;
  final legacy = Directory('${parent.path}/TrueStream');
  if (await legacy.exists()) return legacy.path;
  await next.create(recursive: true);
  return next.path;
}

Future<String> getDefaultDownloadPath() async {
  if (Platform.isAndroid) {
    try {
      return await _resolveDownloadDir(
          Directory('/storage/emulated/0/Download'));
    } catch (_) {
      final appDoc = await getApplicationDocumentsDirectory();
      return '${appDoc.path}/Downloads';
    }
  } else {
    final downloadsDir = await getDownloadsDirectory();
    if (downloadsDir != null) {
      return _resolveDownloadDir(downloadsDir);
    }
    final docDir = await getApplicationDocumentsDirectory();
    return '${docDir.path}/Downloads';
  }
}


enum AppThemeMode {
  system,
  light,
  dark,
}

class AppSettings {
  final bool wifiOnly;
  final bool turboMode;
  final bool completionAlerts;
  final String downloadPath;
  final AppThemeMode themeMode;
  final bool onboardingCompleted;
  final String qualityCeiling;
  final bool audioOnly;
  final String? proxy;
  final bool verbose;
  final bool autoStartDownloadOnShare;
  final String? cookiesPath;
  final bool useCookies;
  final List<Map<String, dynamic>> cookieProfiles;
  final bool youtubeLoggedIn;
  final bool instagramLoggedIn;
  final bool twitterLoggedIn;
  final bool bilibiliLoggedIn;
  final bool twitchLoggedIn;
  final bool splitChapters;
  final String updateChannel;
  final bool downloadSubtitles;
  final List<String> subtitleLanguages;
  final bool downloadAutoSubtitles;
  final bool embedSubtitles;
  final bool saveDescription;
  final bool pngThumbnails;
  final bool saveThumbnails;
  final bool aria2cEnabled;
  final int aria2cChunks;
  final String? aria2cMaxSpeed;
  final bool useGridView;
  final List<String> customTemplates;
  final List<Map<String, dynamic>> observedSources;
  final bool scheduleEnabled;
  final String scheduleTime;
  final List<int> scheduleDays;
  final int scheduleIntervalMinutes;
  final bool scheduleWifiOnly;
  final bool scheduleRequiresCharging;
  final List<String> sponsorBlockCats;
  final bool downloadArchive;
  final bool archiveByFolder;
  final bool hasSeenBatteryPrompt;
  /// Max simultaneous downloads (queue gate). 2 default (Seal-proven 3,
  /// YTDLnis default 1, 10 crash-prone); allowed 1–5, enforced in engine
  /// backstop + Dart queued UI.
  final int maxConcurrentDownloads;

  const AppSettings({
    this.wifiOnly = false,
    this.turboMode = true,
    this.completionAlerts = true,
    this.downloadPath = '/Internal/Videos',
    this.themeMode = AppThemeMode.light,
    this.onboardingCompleted = false,
    this.hasSeenBatteryPrompt = false,
    this.qualityCeiling = '4k',
    this.audioOnly = false,
    this.proxy,
    this.verbose = false,
    this.autoStartDownloadOnShare = false,
    this.cookiesPath,
    this.useCookies = false,
    this.cookieProfiles = const [],
    this.youtubeLoggedIn = false,
    this.instagramLoggedIn = false,
    this.twitterLoggedIn = false,
    this.bilibiliLoggedIn = false,
    this.twitchLoggedIn = false,
    this.splitChapters = false,
    this.updateChannel = 'stable',
    this.downloadSubtitles = false,
    this.subtitleLanguages = const ['en'],
    this.downloadAutoSubtitles = false,
    this.embedSubtitles = false,
    this.saveDescription = false,
    this.pngThumbnails = false,
    this.saveThumbnails = true,
    this.aria2cEnabled = false,
    this.aria2cChunks = 5,
    this.aria2cMaxSpeed,
    this.useGridView = false,
    this.customTemplates = const [],
    this.observedSources = const [],
    this.scheduleEnabled = false,
    this.scheduleTime = '22:00',
    this.scheduleDays = const [1, 2, 3, 4, 5],
    this.scheduleIntervalMinutes = 60,
    this.scheduleWifiOnly = true,
    this.scheduleRequiresCharging = false,
    this.sponsorBlockCats = const ['sponsor'],
    this.downloadArchive = false,
    this.archiveByFolder = true,
    this.maxConcurrentDownloads = 2,
  });

  static const Object _sentinel = Object();

  AppSettings copyWith({
    bool? wifiOnly,
    bool? turboMode,
    bool? completionAlerts,
    String? downloadPath,
    AppThemeMode? themeMode,
    bool? onboardingCompleted,
    bool? hasSeenBatteryPrompt,
    String? qualityCeiling,
    bool? audioOnly,
    String? proxy,
    bool? verbose,
    bool? autoStartDownloadOnShare,
    Object? cookiesPath = _sentinel,
    bool? useCookies,
    List<Map<String, dynamic>>? cookieProfiles,
    bool? youtubeLoggedIn,
    bool? instagramLoggedIn,
    bool? twitterLoggedIn,
    bool? bilibiliLoggedIn,
    bool? twitchLoggedIn,
    bool? splitChapters,
    String? updateChannel,
    bool? downloadSubtitles,
    List<String>? subtitleLanguages,
    bool? downloadAutoSubtitles,
    bool? embedSubtitles,
    bool? saveDescription,
    bool? pngThumbnails,
    bool? saveThumbnails,
    bool? aria2cEnabled,
    int? aria2cChunks,
    Object? aria2cMaxSpeed = _sentinel,
    bool? useGridView,
    List<String>? customTemplates,
    List<Map<String, dynamic>>? observedSources,
    bool? scheduleEnabled,
    String? scheduleTime,
    List<int>? scheduleDays,
    int? scheduleIntervalMinutes,
    bool? scheduleWifiOnly,
    bool? scheduleRequiresCharging,
    List<String>? sponsorBlockCats,
    bool? downloadArchive,
    bool? archiveByFolder,
    int? maxConcurrentDownloads,
  }) {
    return AppSettings(
      wifiOnly: wifiOnly ?? this.wifiOnly,
      turboMode: turboMode ?? this.turboMode,
      completionAlerts: completionAlerts ?? this.completionAlerts,
      downloadPath: downloadPath ?? this.downloadPath,
      themeMode: themeMode ?? this.themeMode,
      onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
      hasSeenBatteryPrompt: hasSeenBatteryPrompt ?? this.hasSeenBatteryPrompt,
      qualityCeiling: qualityCeiling ?? this.qualityCeiling,
      audioOnly: audioOnly ?? this.audioOnly,
      proxy: proxy ?? this.proxy,
      verbose: verbose ?? this.verbose,
      autoStartDownloadOnShare: autoStartDownloadOnShare ?? this.autoStartDownloadOnShare,
      cookiesPath: cookiesPath == _sentinel ? this.cookiesPath : (cookiesPath as String?),
      useCookies: useCookies ?? this.useCookies,
      cookieProfiles: cookieProfiles ?? this.cookieProfiles,
      youtubeLoggedIn: youtubeLoggedIn ?? this.youtubeLoggedIn,
      instagramLoggedIn: instagramLoggedIn ?? this.instagramLoggedIn,
      twitterLoggedIn: twitterLoggedIn ?? this.twitterLoggedIn,
      bilibiliLoggedIn: bilibiliLoggedIn ?? this.bilibiliLoggedIn,
      twitchLoggedIn: twitchLoggedIn ?? this.twitchLoggedIn,
      splitChapters: splitChapters ?? this.splitChapters,
      updateChannel: updateChannel ?? this.updateChannel,
      downloadSubtitles: downloadSubtitles ?? this.downloadSubtitles,
      subtitleLanguages: subtitleLanguages ?? this.subtitleLanguages,
      downloadAutoSubtitles: downloadAutoSubtitles ?? this.downloadAutoSubtitles,
      embedSubtitles: embedSubtitles ?? this.embedSubtitles,
      saveDescription: saveDescription ?? this.saveDescription,
      pngThumbnails: pngThumbnails ?? this.pngThumbnails,
      saveThumbnails: saveThumbnails ?? this.saveThumbnails,
      aria2cEnabled: aria2cEnabled ?? this.aria2cEnabled,
      aria2cChunks: aria2cChunks ?? this.aria2cChunks,
      aria2cMaxSpeed: aria2cMaxSpeed == _sentinel ? this.aria2cMaxSpeed : (aria2cMaxSpeed as String?),
      observedSources: observedSources ?? this.observedSources,
      useGridView: useGridView ?? this.useGridView,
      customTemplates: customTemplates ?? this.customTemplates,
      scheduleEnabled: scheduleEnabled ?? this.scheduleEnabled,
      scheduleTime: scheduleTime ?? this.scheduleTime,
      scheduleDays: scheduleDays ?? this.scheduleDays,
      scheduleIntervalMinutes: scheduleIntervalMinutes ?? this.scheduleIntervalMinutes,
      scheduleWifiOnly: scheduleWifiOnly ?? this.scheduleWifiOnly,
      scheduleRequiresCharging: scheduleRequiresCharging ?? this.scheduleRequiresCharging,
      sponsorBlockCats: sponsorBlockCats ?? this.sponsorBlockCats,
      downloadArchive: downloadArchive ?? this.downloadArchive,
      archiveByFolder: archiveByFolder ?? this.archiveByFolder,
      maxConcurrentDownloads: maxConcurrentDownloads ?? this.maxConcurrentDownloads,
    );
  }
}

final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError('Initialize shared preferences in main()');
});

class SettingsNotifier extends StateNotifier<AppSettings> {
  final SharedPreferences _prefs;

  SettingsNotifier(this._prefs) : super(const AppSettings()) {
    _loadSettings();
  }

  void _loadSettings() {
    final wifiOnly = _prefs.getBool('wifiOnly') ?? false;
    final turboMode = _prefs.getBool('turboMode') ?? true;
    final completionAlerts = _prefs.getBool('completionAlerts') ?? true;
    final downloadPath = _prefs.getString('downloadPath') ?? '/Internal/Videos';
    final themeIndex = _prefs.getInt('themeMode') ?? AppThemeMode.light.index;
    final onboardingCompleted = _prefs.getBool('onboardingCompleted') ?? false;
    final hasSeenBatteryPrompt = _prefs.getBool('hasSeenBatteryPrompt') ?? false;
    final qualityCeiling = _prefs.getString('qualityCeiling') ?? '4k';
    final audioOnly = _prefs.getBool('audioOnly') ?? false;
    final proxy = _prefs.getString('proxy');
    final verbose = _prefs.getBool('verbose') ?? false;
    final autoStartDownloadOnShare = _prefs.getBool('autoStartDownloadOnShare') ?? false;
    final cookiesPath = _prefs.getString('cookiesPath');
    final youtubeLoggedIn = _prefs.getBool('youtubeLoggedIn') ?? false;
    final instagramLoggedIn = _prefs.getBool('instagramLoggedIn') ?? false;
    final twitterLoggedIn = _prefs.getBool('twitterLoggedIn') ?? false;
    final bilibiliLoggedIn = _prefs.getBool('bilibiliLoggedIn') ?? false;
    final twitchLoggedIn = _prefs.getBool('twitchLoggedIn') ?? false;
    final splitChapters = _prefs.getBool('splitChapters') ?? false;
    final updateChannel = _prefs.getString('updateChannel') ?? 'stable';
    final downloadSubtitles = _prefs.getBool('downloadSubtitles') ?? false;
    final subtitleLanguages = _prefs.getStringList('subtitleLanguages') ?? ['en'];
    final downloadAutoSubtitles = _prefs.getBool('downloadAutoSubtitles') ?? false;
    final embedSubtitles = _prefs.getBool('embedSubtitles') ?? false;
    final saveDescription = _prefs.getBool('saveDescription') ?? false;
    final pngThumbnails = _prefs.getBool('pngThumbnails') ?? false;
    final saveThumbnails = _prefs.getBool('saveThumbnails') ?? true;
    final aria2cEnabled = _prefs.getBool('aria2cEnabled') ?? false;
    final aria2cChunks = _prefs.getInt('aria2cChunks') ?? 5;
    final aria2cMaxSpeed = _prefs.getString('aria2cMaxSpeed');
    final useGridView = _prefs.getBool('useGridView') ?? false;
    final customTemplatesJson = _prefs.getString('customTemplates');
    final customTemplates = customTemplatesJson != null
        ? List<String>.from(jsonDecode(customTemplatesJson) as List)
        : <String>[];
    final observedSourcesJson = _prefs.getString('observedSources');
    final observedSources = observedSourcesJson != null
        ? List<Map<String, dynamic>>.from(
            (jsonDecode(observedSourcesJson) as List).map((e) => Map<String, dynamic>.from(e as Map)),
          )
        : <Map<String, dynamic>>[];
    final scheduleEnabled = _prefs.getBool('scheduleEnabled') ?? false;
    final scheduleTime = _prefs.getString('scheduleTime') ?? '22:00';
    final scheduleDaysRaw = _prefs.getStringList('scheduleDays') ?? ['1', '2', '3', '4', '5'];
    final scheduleDays = scheduleDaysRaw.map((e) => int.tryParse(e) ?? 1).toList();
    final scheduleIntervalMinutes = _prefs.getInt('scheduleIntervalMinutes') ?? 60;
    final scheduleWifiOnly = _prefs.getBool('scheduleWifiOnly') ?? true;
    final scheduleRequiresCharging = _prefs.getBool('scheduleRequiresCharging') ?? false;
    final sponsorBlockCats = _prefs.getStringList('sponsorBlockCats') ?? ['sponsor'];
    final downloadArchive = _prefs.getBool('downloadArchive') ?? false;
    final archiveByFolder = _prefs.getBool('archiveByFolder') ?? true;
    final maxConcurrentDownloads =
        (_prefs.getInt('maxConcurrentDownloads') ?? 2).clamp(1, 5);
    final useCookies = _prefs.getBool('useCookies') ?? false;
    final cookieProfilesJson = _prefs.getStringList('cookieProfiles') ?? [];
    final cookieProfiles = <Map<String, dynamic>>[];
    for (final raw in cookieProfilesJson) {
      try {
        cookieProfiles.add(Map<String, dynamic>.from(jsonDecode(raw) as Map));
      } catch (_) {}
    }

    state = AppSettings(
      wifiOnly: wifiOnly,
      turboMode: turboMode,
      completionAlerts: completionAlerts,
      downloadPath: downloadPath,
      themeMode: AppThemeMode.values[themeIndex],
      onboardingCompleted: onboardingCompleted,
      hasSeenBatteryPrompt: hasSeenBatteryPrompt,
      qualityCeiling: qualityCeiling,
      audioOnly: audioOnly,
      proxy: proxy,
      verbose: verbose,
      autoStartDownloadOnShare: autoStartDownloadOnShare,
      cookiesPath: cookiesPath,
      youtubeLoggedIn: youtubeLoggedIn,
      instagramLoggedIn: instagramLoggedIn,
      twitterLoggedIn: twitterLoggedIn,
      bilibiliLoggedIn: bilibiliLoggedIn,
      twitchLoggedIn: twitchLoggedIn,
      splitChapters: splitChapters,
      updateChannel: updateChannel,
      downloadSubtitles: downloadSubtitles,
      subtitleLanguages: subtitleLanguages,
      downloadAutoSubtitles: downloadAutoSubtitles,
      embedSubtitles: embedSubtitles,
      saveDescription: saveDescription,
      pngThumbnails: pngThumbnails,
      saveThumbnails: saveThumbnails,
      aria2cEnabled: aria2cEnabled,
      aria2cChunks: aria2cChunks,
      aria2cMaxSpeed: aria2cMaxSpeed,
      customTemplates: customTemplates,
      observedSources: observedSources,
      scheduleEnabled: scheduleEnabled,
      scheduleTime: scheduleTime,
      scheduleDays: scheduleDays,
      scheduleIntervalMinutes: scheduleIntervalMinutes,
      scheduleWifiOnly: scheduleWifiOnly,
      scheduleRequiresCharging: scheduleRequiresCharging,
      sponsorBlockCats: sponsorBlockCats,
      useCookies: useCookies,
      cookieProfiles: cookieProfiles,
      useGridView: useGridView,
      downloadArchive: downloadArchive,
      archiveByFolder: archiveByFolder,
      maxConcurrentDownloads: maxConcurrentDownloads,
    );
  }

  void toggleWifiOnly() {
    final newValue = !state.wifiOnly;
    _prefs.setBool('wifiOnly', newValue);
    state = state.copyWith(wifiOnly: newValue);
  }

  void toggleTurboMode() {
    final newValue = !state.turboMode;
    _prefs.setBool('turboMode', newValue);
    state = state.copyWith(turboMode: newValue);
  }

  void toggleCompletionAlerts() {
    final newValue = !state.completionAlerts;
    _prefs.setBool('completionAlerts', newValue);
    state = state.copyWith(completionAlerts: newValue);
  }

  void setDownloadPath(String path) {
    _prefs.setString('downloadPath', path);
    state = state.copyWith(downloadPath: path);
  }

  void setThemeMode(AppThemeMode mode) {
    _prefs.setInt('themeMode', mode.index);
    state = state.copyWith(themeMode: mode);
  }

  void completeOnboarding() {
    _prefs.setBool('onboardingCompleted', true);
    state = state.copyWith(onboardingCompleted: true);
  }

  void setHasSeenBatteryPrompt(bool seen) {
    _prefs.setBool('hasSeenBatteryPrompt', seen);
    state = state.copyWith(hasSeenBatteryPrompt: seen);
  }

  void setQualityCeiling(String value) {
    _prefs.setString('qualityCeiling', value);
    state = state.copyWith(qualityCeiling: value);
  }

  void toggleAudioOnly() {
    final newValue = !state.audioOnly;
    _prefs.setBool('audioOnly', newValue);
    state = state.copyWith(audioOnly: newValue);
  }

  void setProxy(String? value) {
    if (value == null || value.isEmpty) {
      _prefs.remove('proxy');
    } else {
      _prefs.setString('proxy', value);
    }
    state = state.copyWith(proxy: value);
  }

  void toggleVerbose() {
    final newValue = !state.verbose;
    _prefs.setBool('verbose', newValue);
    state = state.copyWith(verbose: newValue);
  }

  void toggleAutoStartDownloadOnShare() {
    final newValue = !state.autoStartDownloadOnShare;
    _prefs.setBool('autoStartDownloadOnShare', newValue);
    state = state.copyWith(autoStartDownloadOnShare: newValue);
  }

  void setCookiesPath(String? path) {
    if (path == null) {
      _prefs.remove('cookiesPath');
    } else {
      _prefs.setString('cookiesPath', path);
    }
    state = state.copyWith(cookiesPath: path);
  }

  void setUseCookies(bool value) {
    _prefs.setBool('useCookies', value);
    state = state.copyWith(useCookies: value);
  }

  void _persistCookieProfiles(List<Map<String, dynamic>> profiles) {
    _prefs.setStringList(
      'cookieProfiles',
      profiles.map((p) => jsonEncode(p)).toList(),
    );
    state = state.copyWith(cookieProfiles: profiles);
  }

  /// Insert or replace the profile for [url] (matched case-insensitively
  /// on the exact URL string). [lines] are Netscape data lines.
  void upsertCookieProfile({
    required String url,
    required String description,
    required List<String> lines,
  }) {
    final updated = [...state.cookieProfiles];
    final idx = updated.indexWhere(
      (p) => (p['url'] as String? ?? '').toLowerCase() == url.toLowerCase(),
    );
    final entry = {
      'id': idx == -1
          ? DateTime.now().millisecondsSinceEpoch.toString()
          : updated[idx]['id'],
      'url': url,
      'description': description,
      'content': lines,
      'enabled': idx == -1 ? true : (updated[idx]['enabled'] as bool? ?? true),
    };
    if (idx == -1) {
      updated.add(entry);
    } else {
      updated[idx] = entry;
    }
    _persistCookieProfiles(updated);
  }

  void toggleCookieProfile(String id) {
    final updated = state.cookieProfiles.map((p) {
      if (p['id'] != id) return p;
      return {...p, 'enabled': !(p['enabled'] as bool? ?? true)};
    }).toList();
    _persistCookieProfiles(updated);
  }

  void deleteCookieProfile(String id) {
    _persistCookieProfiles(
      state.cookieProfiles.where((p) => p['id'] != id).toList(),
    );
  }

  void clearCookieProfiles() => _persistCookieProfiles([]);

  void setYoutubeLoggedIn(bool value) {
    _prefs.setBool('youtubeLoggedIn', value);
    state = state.copyWith(youtubeLoggedIn: value);
  }

  void setInstagramLoggedIn(bool value) {
    _prefs.setBool('instagramLoggedIn', value);
    state = state.copyWith(instagramLoggedIn: value);
  }

  void setTwitterLoggedIn(bool value) {
    _prefs.setBool('twitterLoggedIn', value);
    state = state.copyWith(twitterLoggedIn: value);
  }

  void setBilibiliLoggedIn(bool value) {
    _prefs.setBool('bilibiliLoggedIn', value);
    state = state.copyWith(bilibiliLoggedIn: value);
  }

  void setTwitchLoggedIn(bool value) {
    _prefs.setBool('twitchLoggedIn', value);
    state = state.copyWith(twitchLoggedIn: value);
  }

  void setUpdateChannel(String channel) {
    _prefs.setString('updateChannel', channel);
    state = state.copyWith(updateChannel: channel);
  }

  void toggleSplitChapters() {
    final newValue = !state.splitChapters;
    _prefs.setBool('splitChapters', newValue);
    state = state.copyWith(splitChapters: newValue);
  }

  void toggleDownloadSubtitles() {
    final newValue = !state.downloadSubtitles;
    _prefs.setBool('downloadSubtitles', newValue);
    state = state.copyWith(downloadSubtitles: newValue);
  }

  void setSubtitleLanguages(List<String> languages) {
    _prefs.setStringList('subtitleLanguages', languages);
    state = state.copyWith(subtitleLanguages: languages);
  }

  void toggleDownloadAutoSubtitles() {
    final newValue = !state.downloadAutoSubtitles;
    _prefs.setBool('downloadAutoSubtitles', newValue);
    state = state.copyWith(downloadAutoSubtitles: newValue);
  }

  void toggleEmbedSubtitles() {
    final newValue = !state.embedSubtitles;
    _prefs.setBool('embedSubtitles', newValue);
    state = state.copyWith(embedSubtitles: newValue);
  }

  void toggleSaveDescription() {
    final newValue = !state.saveDescription;
    _prefs.setBool('saveDescription', newValue);
    state = state.copyWith(saveDescription: newValue);
  }

  void togglePngThumbnails() {
    final newValue = !state.pngThumbnails;
    _prefs.setBool('pngThumbnails', newValue);
    state = state.copyWith(pngThumbnails: newValue);
  }

  void toggleSaveThumbnails() {
    final newValue = !state.saveThumbnails;
    _prefs.setBool('saveThumbnails', newValue);
    state = state.copyWith(saveThumbnails: newValue);
  }

  void setUseGridView(bool value) {
    _prefs.setBool('useGridView', value);
    state = state.copyWith(useGridView: value);
  }

  void toggleGridView() {
    setUseGridView(!state.useGridView);
  }

  void setAria2cEnabled(bool value) {
    _prefs.setBool('aria2cEnabled', value);
    state = state.copyWith(aria2cEnabled: value);
  }

  void setAria2cChunks(int value) {
    _prefs.setInt('aria2cChunks', value);
    state = state.copyWith(aria2cChunks: value);
  }

  void setAria2cMaxSpeed(String? value) {
    if (value == null || value.isEmpty) {
      _prefs.remove('aria2cMaxSpeed');
    } else {
      _prefs.setString('aria2cMaxSpeed', value);
    }
    state = state.copyWith(aria2cMaxSpeed: value);
  }

  void setScheduleEnabled(bool value) {
    _prefs.setBool('scheduleEnabled', value);
    state = state.copyWith(scheduleEnabled: value);
  }

  void setScheduleTime(String value) {
    _prefs.setString('scheduleTime', value);
    state = state.copyWith(scheduleTime: value);
  }

  void setScheduleDays(List<int> value) {
    _prefs.setStringList('scheduleDays', value.map((e) => e.toString()).toList());
    state = state.copyWith(scheduleDays: value);
  }

  void setScheduleIntervalMinutes(int value) {
    _prefs.setInt('scheduleIntervalMinutes', value);
    state = state.copyWith(scheduleIntervalMinutes: value);
  }

  void setScheduleWifiOnly(bool value) {
    _prefs.setBool('scheduleWifiOnly', value);
    state = state.copyWith(scheduleWifiOnly: value);
  }

  void setScheduleRequiresCharging(bool value) {
    _prefs.setBool('scheduleRequiresCharging', value);
    state = state.copyWith(scheduleRequiresCharging: value);
  }

  void setSponsorBlockCats(List<String> cats) {
    _prefs.setStringList('sponsorBlockCats', cats);
    state = state.copyWith(sponsorBlockCats: cats);
  }

  void setDownloadArchive(bool value) {
    _prefs.setBool('downloadArchive', value);
    state = state.copyWith(downloadArchive: value);
  }

  void setArchiveByFolder(bool value) {
    _prefs.setBool('archiveByFolder', value);
    state = state.copyWith(archiveByFolder: value);
  }

  void setMaxConcurrentDownloads(int value) {
    final clamped = value.clamp(1, 5);
    _prefs.setInt('maxConcurrentDownloads', clamped);
    state = state.copyWith(maxConcurrentDownloads: clamped);
  }

  Future<void> setCustomTemplates(List<String> templates) async {
    await _prefs.setString('customTemplates', jsonEncode(templates));
    state = state.copyWith(customTemplates: templates);
  }

  void addObservedSource(Map<String, dynamic> source) {
    final updated = [...state.observedSources, source];
    _prefs.setString('observedSources', jsonEncode(updated));
    state = state.copyWith(observedSources: updated);
  }

  void removeObservedSource(int index) {
    final updated = [...state.observedSources]..removeAt(index);
    _prefs.setString('observedSources', jsonEncode(updated));
    state = state.copyWith(observedSources: updated);
  }

  void toggleObservedSource(int index) {
    final updated = [...state.observedSources];
    updated[index] = {
      ...updated[index],
      'enabled': !(updated[index]['enabled'] as bool? ?? true),
    };
    _prefs.setString('observedSources', jsonEncode(updated));
    state = state.copyWith(observedSources: updated);
  }

  Future<void> clearAllCookies(String appDir) async {
    final defaultCookiesFile = File('$appDir/cookies.txt');
    try {
      if (await defaultCookiesFile.exists()) {
        await defaultCookiesFile.delete();
      }
    } catch (_) {}

    final customPath = state.cookiesPath;
    if (customPath != null && customPath != defaultCookiesFile.path) {
      try {
        final customCookiesFile = File(customPath);
        if (await customCookiesFile.exists()) {
          await customCookiesFile.delete();
        }
      } catch (_) {}
    }

    await _prefs.remove('cookiesPath');
    await _prefs.setBool('youtubeLoggedIn', false);
    await _prefs.setBool('instagramLoggedIn', false);
    await _prefs.setBool('twitterLoggedIn', false);
    await _prefs.setBool('bilibiliLoggedIn', false);
    await _prefs.setBool('twitchLoggedIn', false);

    state = state.copyWith(
      cookiesPath: null,
      youtubeLoggedIn: false,
      instagramLoggedIn: false,
      twitterLoggedIn: false,
      bilibiliLoggedIn: false,
      twitchLoggedIn: false,
    );
  }
}

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, AppSettings>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  return SettingsNotifier(prefs);
});

/// SEC-04: custom yt-dlp argument templates are user-typed CLI fragments.
/// They are stored but never executed today; when (if) a command runner
/// consumes them, path-escape flags must already be gated at input.
/// Returns an error string when the args must be rejected, else null.
String? validateTemplateArgs(String args) {
  if (args.contains('\x00')) return 'Template contains invalid characters.';
  if (args.length > 2000) return 'Template is too long (max 2000 chars).';
  const pathFlags = {'-o', '--output', '-P', '--paths'};
  final tokens = args.split(RegExp(r'\s+'));
  for (var i = 0; i < tokens.length; i++) {
    final t = tokens[i];
    String? value;
    if (pathFlags.contains(t) && i + 1 < tokens.length) {
      value = tokens[i + 1];
    } else {
      for (final flag in pathFlags) {
        final prefix = '$flag=';
        if (t.startsWith(prefix)) value = t.substring(prefix.length);
      }
      // Short -oVALUE form (e.g. -o%(title)s).
      if (value == null && t.startsWith('-o') && t.length > 2 && !t.startsWith('--')) {
        value = t.substring(2);
      }
    }
    if (value == null || value.isEmpty) continue;
    final v = value.replaceAll(RegExp('^["\']|["\']\$'), '');
    if (v.startsWith('/') ||
        v.startsWith('\\') ||
        RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(v) ||
        v.startsWith('\\\\') ||
        v.split(RegExp(r'[\\/]')).contains('..')) {
      return 'Blocked: output path escapes the download folder ($t).';
    }
  }
  return null;
}

/// True when the args request shell execution. Allowed (user agency, same
/// as Seal-style custom commands) but the UI must warn: only run templates
/// you typed yourself.
bool templateWantsExec(String args) {
  return RegExp(r'(^|\s)--exec(-before-download|-after-move)?(\s|=|$)')
      .hasMatch(args);
}
