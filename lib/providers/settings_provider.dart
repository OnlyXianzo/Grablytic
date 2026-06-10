import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<String> getDefaultDownloadPath() async {
  if (Platform.isAndroid) {
    final dir = Directory('/storage/emulated/0/Download/TrueStream');
    if (!await dir.exists()) {
      try {
        await dir.create(recursive: true);
      } catch (_) {
        final appDoc = await getApplicationDocumentsDirectory();
        return '${appDoc.path}/Downloads';
      }
    }
    return dir.path;
  } else {
    final downloadsDir = await getDownloadsDirectory();
    if (downloadsDir != null) {
      final dir = Directory('${downloadsDir.path}/TrueStream');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir.path;
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
  final bool aria2cEnabled;
  final int aria2cChunks;
  final String? aria2cMaxSpeed;
  final bool useGridView;
  final List<String> customTemplates;
  final List<Map<String, dynamic>> observedSources;
  final bool scheduleEnabled;
  final String scheduleTime;
  final List<int> scheduleDays;
  final List<String> sponsorBlockCats;
  final bool downloadArchive;
  final bool archiveByFolder;

  const AppSettings({
    this.wifiOnly = false,
    this.turboMode = true,
    this.completionAlerts = true,
    this.downloadPath = '/Internal/Videos',
    this.themeMode = AppThemeMode.light,
    this.onboardingCompleted = false,
    this.qualityCeiling = '4k',
    this.audioOnly = false,
    this.proxy,
    this.verbose = false,
    this.autoStartDownloadOnShare = false,
    this.cookiesPath,
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
    this.aria2cEnabled = false,
    this.aria2cChunks = 5,
    this.aria2cMaxSpeed,
    this.useGridView = false,
    this.customTemplates = const [],
    this.observedSources = const [],
    this.scheduleEnabled = false,
    this.scheduleTime = '22:00',
    this.scheduleDays = const [1, 2, 3, 4, 5],
    this.sponsorBlockCats = const ['sponsor'],
    this.downloadArchive = false,
    this.archiveByFolder = true,
  });

  static const Object _sentinel = Object();

  AppSettings copyWith({
    bool? wifiOnly,
    bool? turboMode,
    bool? completionAlerts,
    String? downloadPath,
    AppThemeMode? themeMode,
    bool? onboardingCompleted,
    String? qualityCeiling,
    bool? audioOnly,
    String? proxy,
    bool? verbose,
    bool? autoStartDownloadOnShare,
    Object? cookiesPath = _sentinel,
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
    bool? aria2cEnabled,
    int? aria2cChunks,
    Object? aria2cMaxSpeed = _sentinel,
    bool? useGridView,
    List<String>? customTemplates,
    List<Map<String, dynamic>>? observedSources,
    bool? scheduleEnabled,
    String? scheduleTime,
    List<int>? scheduleDays,
    List<String>? sponsorBlockCats,
    bool? downloadArchive,
    bool? archiveByFolder,
  }) {
    return AppSettings(
      wifiOnly: wifiOnly ?? this.wifiOnly,
      turboMode: turboMode ?? this.turboMode,
      completionAlerts: completionAlerts ?? this.completionAlerts,
      downloadPath: downloadPath ?? this.downloadPath,
      themeMode: themeMode ?? this.themeMode,
      onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
      qualityCeiling: qualityCeiling ?? this.qualityCeiling,
      audioOnly: audioOnly ?? this.audioOnly,
      proxy: proxy ?? this.proxy,
      verbose: verbose ?? this.verbose,
      autoStartDownloadOnShare: autoStartDownloadOnShare ?? this.autoStartDownloadOnShare,
      cookiesPath: cookiesPath == _sentinel ? this.cookiesPath : (cookiesPath as String?),
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
      aria2cEnabled: aria2cEnabled ?? this.aria2cEnabled,
      aria2cChunks: aria2cChunks ?? this.aria2cChunks,
      aria2cMaxSpeed: aria2cMaxSpeed == _sentinel ? this.aria2cMaxSpeed : (aria2cMaxSpeed as String?),
      observedSources: observedSources ?? this.observedSources,
      useGridView: useGridView ?? this.useGridView,
      sponsorBlockCats: sponsorBlockCats ?? this.sponsorBlockCats,
      downloadArchive: downloadArchive ?? this.downloadArchive,
      archiveByFolder: archiveByFolder ?? this.archiveByFolder,
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
    final sponsorBlockCats = _prefs.getStringList('sponsorBlockCats') ?? ['sponsor'];
    final downloadArchive = _prefs.getBool('downloadArchive') ?? false;
    final archiveByFolder = _prefs.getBool('archiveByFolder') ?? true;

    state = AppSettings(
      wifiOnly: wifiOnly,
      turboMode: turboMode,
      completionAlerts: completionAlerts,
      downloadPath: downloadPath,
      themeMode: AppThemeMode.values[themeIndex],
      onboardingCompleted: onboardingCompleted,
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
      aria2cEnabled: aria2cEnabled,
      aria2cChunks: aria2cChunks,
      aria2cMaxSpeed: aria2cMaxSpeed,
      customTemplates: customTemplates,
      observedSources: observedSources,
      scheduleEnabled: scheduleEnabled,
      scheduleTime: scheduleTime,
      scheduleDays: scheduleDays,
      sponsorBlockCats: sponsorBlockCats,
      useGridView: useGridView,
      downloadArchive: downloadArchive,
      archiveByFolder: archiveByFolder,
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

  void setUseGridView(bool value) {
    _prefs.setBool('useGridView', value);
    state = state.copyWith(useGridView: value);
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

  void setCustomTemplates(List<String> templates) {
    _prefs.setString('customTemplates', jsonEncode(templates));
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
