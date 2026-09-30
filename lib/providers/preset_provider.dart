import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'settings_provider.dart';

class DownloadPreset {
  final String id;
  final String name;
  final bool audioOnly;
  final String qualityCeiling; // '4k', '1080p', '720p', '480p', 'best'
  final String preferredCodec; // 'av01', 'vp9', 'h264', 'none'
  final String preferredContainer; // 'mkv', 'mp4', 'webm', 'flac', 'opus', 'mp3'
  final bool isPredefined;

  const DownloadPreset({
    required this.id,
    required this.name,
    required this.audioOnly,
    required this.qualityCeiling,
    required this.preferredCodec,
    required this.preferredContainer,
    this.isPredefined = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'audioOnly': audioOnly,
        'qualityCeiling': qualityCeiling,
        'preferredCodec': preferredCodec,
        'preferredContainer': preferredContainer,
        'isPredefined': isPredefined,
      };

  factory DownloadPreset.fromJson(Map<String, dynamic> json) {
    return DownloadPreset(
      id: json['id'] as String,
      name: json['name'] as String,
      audioOnly: json['audioOnly'] as bool? ?? false,
      qualityCeiling: json['qualityCeiling'] as String? ?? 'best',
      preferredCodec: json['preferredCodec'] as String? ?? 'vp9',
      preferredContainer: json['preferredContainer'] as String? ?? 'mkv',
      isPredefined: json['isPredefined'] as bool? ?? false,
    );
  }
}

final List<DownloadPreset> predefinedPresets = [
  const DownloadPreset(
    id: 'preset_4k',
    name: 'Ultra Quality (4K)',
    audioOnly: false,
    qualityCeiling: '4k',
    preferredCodec: 'av01',
    preferredContainer: 'mkv',
    isPredefined: true,
  ),
  const DownloadPreset(
    id: 'preset_1080p',
    name: 'Full HD (1080p)',
    audioOnly: false,
    qualityCeiling: '1080p',
    preferredCodec: 'vp9',
    preferredContainer: 'mkv',
    isPredefined: true,
  ),
  const DownloadPreset(
    id: 'preset_720p',
    name: 'High Definition (720p)',
    audioOnly: false,
    qualityCeiling: '720p',
    preferredCodec: 'h264',
    preferredContainer: 'mp4',
    isPredefined: true,
  ),
  const DownloadPreset(
    id: 'preset_480p',
    name: 'Data Saver (480p)',
    audioOnly: false,
    qualityCeiling: '480p', // Real 480p ceiling (engine height_map).
    preferredCodec: 'h264',
    preferredContainer: 'mp4',
    isPredefined: true,
  ),
  const DownloadPreset(
    id: 'preset_flac',
    name: 'Lossless Audio (FLAC)',
    audioOnly: true,
    qualityCeiling: 'best',
    preferredCodec: 'none',
    preferredContainer: 'flac',
    isPredefined: true,
  ),
  const DownloadPreset(
    id: 'preset_opus',
    name: 'High Quality Audio (Opus)',
    audioOnly: true,
    qualityCeiling: 'best',
    preferredCodec: 'none',
    preferredContainer: 'opus',
    isPredefined: true,
  ),
  const DownloadPreset(
    id: 'preset_mp3',
    name: 'Standard Audio (MP3)',
    audioOnly: true,
    qualityCeiling: 'best',
    preferredCodec: 'none',
    preferredContainer: 'mp3',
    isPredefined: true,
  ),
];

class PresetsState {
  final List<DownloadPreset> presets;
  final String activePresetId;

  const PresetsState({
    required this.presets,
    required this.activePresetId,
  });

  DownloadPreset get activePreset {
    return presets.firstWhere(
      (p) => p.id == activePresetId,
      orElse: () => predefinedPresets[1], // default to Full HD
    );
  }
}

class PresetsNotifier extends StateNotifier<PresetsState> {
  final SharedPreferences _prefs;

  PresetsNotifier(this._prefs)
      : super(PresetsState(
          presets: predefinedPresets,
          activePresetId: 'preset_1080p',
        )) {
    _loadPresets();
  }

  void _loadPresets() {
    final activeId = _prefs.getString('activePresetId') ?? 'preset_1080p';
    final customJson = _prefs.getStringList('customPresets') ?? [];
    
    final List<DownloadPreset> list = [...predefinedPresets];
    for (final jsonStr in customJson) {
      try {
        final Map<String, dynamic> map = jsonDecode(jsonStr);
        list.add(DownloadPreset.fromJson(map));
      } catch (_) {}
    }

    state = PresetsState(
      presets: list,
      activePresetId: activeId,
    );
  }

  void setActivePreset(String id) {
    _prefs.setString('activePresetId', id);
    state = PresetsState(
      presets: state.presets,
      activePresetId: id,
    );
  }

  void savePreset(DownloadPreset preset) {
    final index = state.presets.indexWhere((p) => p.id == preset.id);
    final List<DownloadPreset> updatedList = [...state.presets];
    
    if (index != -1) {
      if (updatedList[index].isPredefined) return; // Cannot edit predefined presets
      updatedList[index] = preset;
    } else {
      updatedList.add(preset);
    }

    _saveCustomPresets(updatedList);
  }

  void deletePreset(String id) {
    final preset = state.presets.firstWhere((p) => p.id == id, orElse: () => throw Exception('Preset not found'));
    if (preset.isPredefined) return; // Cannot delete predefined presets

    final List<DownloadPreset> updatedList = state.presets.where((p) => p.id != id).toList();
    
    String activeId = state.activePresetId;
    if (activeId == id) {
      activeId = 'preset_1080p'; // fallback
      _prefs.setString('activePresetId', activeId);
    }

    _saveCustomPresets(updatedList, activeId: activeId);
  }

  void _saveCustomPresets(List<DownloadPreset> list, {String? activeId}) {
    final customList = list.where((p) => !p.isPredefined).toList();
    final jsonList = customList.map((p) => jsonEncode(p.toJson())).toList();
    _prefs.setStringList('customPresets', jsonList);

    state = PresetsState(
      presets: list,
      activePresetId: activeId ?? state.activePresetId,
    );
  }
}

final presetsProvider = StateNotifierProvider<PresetsNotifier, PresetsState>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  return PresetsNotifier(prefs);
});
