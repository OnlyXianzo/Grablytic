import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../providers/preset_provider.dart';

class ProfileEditorScreen extends ConsumerStatefulWidget {
  final String? profileId;

  const ProfileEditorScreen({super.key, this.profileId});

  @override
  ConsumerState<ProfileEditorScreen> createState() =>
      _ProfileEditorScreenState();
}

class _ProfileEditorScreenState extends ConsumerState<ProfileEditorScreen> {
  final _nameController = TextEditingController();
  String _selectedQuality = '1080p';
  String _selectedCodec = 'vp9';
  bool _audioOnly = false;
  String _selectedContainer = 'mkv';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.profileId != null) {
        final presets = ref.read(presetsProvider).presets;
        final preset = presets.firstWhere((p) => p.id == widget.profileId);
        _nameController.text = preset.name;
        setState(() {
          _selectedQuality = preset.qualityCeiling;
          _selectedCodec = preset.preferredCodec;
          _audioOnly = preset.audioOnly;
          _selectedContainer = preset.preferredContainer;
        });
      }
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.profileId == null ? 'Create Preset' : 'Edit Preset'),
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.primary,
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'PRESET DETAILS',
                style: textTheme.labelSmall?.copyWith(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _nameController,
                decoration: InputDecoration(
                  labelText: 'Preset Name',
                  labelStyle: TextStyle(color: colorScheme.outline),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(
                      color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: colorScheme.primary),
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'QUALITY OPTIONS',
                style: textTheme.labelSmall?.copyWith(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              SwitchListTile.adaptive(
                title: const Text('Audio Only'),
                subtitle: const Text('Discard video stream after download'),
                value: _audioOnly,
                onChanged: (val) {
                  setState(() {
                    _audioOnly = val;
                    if (val) {
                      if (_selectedContainer != 'mp3' &&
                          _selectedContainer != 'opus' &&
                          _selectedContainer != 'flac') {
                        _selectedContainer = 'mp3';
                      }
                    } else {
                      if (_selectedContainer == 'mp3' ||
                          _selectedContainer == 'opus' ||
                          _selectedContainer == 'flac') {
                        _selectedContainer = 'mkv';
                      }
                    }
                  });
                },
                activeTrackColor: colorScheme.primary,
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 16),
              if (!_audioOnly) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Quality', style: textTheme.bodyLarge),
                    Semantics(
                      label: 'Quality, currently $_selectedQuality',
                      child: DropdownButton<String>(
                        value: _selectedQuality,
                        dropdownColor: colorScheme.surfaceContainerHigh,
                        items: const [
                          DropdownMenuItem(
                            value: '4k',
                            child: Text('4K Ultra HD'),
                          ),
                          DropdownMenuItem(
                            value: '1080p',
                            child: Text('1080p Full HD'),
                          ),
                          DropdownMenuItem(
                            value: '720p',
                            child: Text('720p HD'),
                          ),
                          DropdownMenuItem(
                            value: '480p',
                            child: Text('480p Data Saver'),
                          ),
                          DropdownMenuItem(
                            value: 'best',
                            child: Text('Best Available'),
                          ),
                        ],
                        onChanged: (val) {
                          if (val != null) {
                            setState(() => _selectedQuality = val);
                          }
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Preferred Codec', style: textTheme.bodyLarge),
                    Semantics(
                      label: 'Preferred Codec, currently $_selectedCodec',
                      child: DropdownButton<String>(
                        value: _selectedCodec,
                        dropdownColor: colorScheme.surfaceContainerHigh,
                        items: const [
                          DropdownMenuItem(
                            value: 'av01',
                            child: Text('AV1 (Maximum Compression)'),
                          ),
                          DropdownMenuItem(
                            value: 'vp9',
                            child: Text('VP9 (Balanced)'),
                          ),
                          DropdownMenuItem(
                            value: 'h264',
                            child: Text('H.264 (Universal)'),
                          ),
                        ],
                        onChanged: (val) {
                          if (val != null) setState(() => _selectedCodec = val);
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Format', style: textTheme.bodyLarge),
                  Semantics(
                    label: 'Format, currently $_selectedContainer',
                    child: DropdownButton<String>(
                      value: _selectedContainer,
                      dropdownColor: colorScheme.surfaceContainerHigh,
                      items: _audioOnly
                          ? const [
                              DropdownMenuItem(
                                value: 'mp3',
                                child: Text('MP3'),
                              ),
                              DropdownMenuItem(
                                value: 'opus',
                                child: Text('Opus'),
                              ),
                              DropdownMenuItem(
                                value: 'flac',
                                child: Text('FLAC (Lossless)'),
                              ),
                            ]
                          : const [
                              DropdownMenuItem(
                                value: 'mkv',
                                child: Text('MKV'),
                              ),
                              DropdownMenuItem(
                                value: 'mp4',
                                child: Text('MP4'),
                              ),
                              DropdownMenuItem(
                                value: 'webm',
                                child: Text('WebM'),
                              ),
                            ],
                      onChanged: (val) {
                        if (val != null) {
                          setState(() => _selectedContainer = val);
                        }
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 48),
              Row(
                children: [
                  if (widget.profileId != null) ...[
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          ref
                              .read(presetsProvider.notifier)
                              .deletePreset(widget.profileId!);
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            styledSnackBar(context, 'Preset deleted'),
                          );
                        },
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.red),
                          foregroundColor: Colors.red,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text('Delete'),
                      ),
                    ),
                    const SizedBox(width: 16),
                  ],
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        final name = _nameController.text.trim();
                        if (name.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            styledSnackBar(context, 'Please enter a preset name'),
                          );
                          return;
                        }

                        final preset = DownloadPreset(
                          id:
                              widget.profileId ??
                              DateTime.now().millisecondsSinceEpoch.toString(),
                          name: name,
                          audioOnly: _audioOnly,
                          qualityCeiling: _audioOnly
                              ? 'best'
                              : _selectedQuality,
                          preferredCodec: _audioOnly ? 'none' : _selectedCodec,
                          preferredContainer: _selectedContainer,
                          isPredefined: false,
                        );

                        ref.read(presetsProvider.notifier).savePreset(preset);

                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          styledSnackBar(context, 'Preset saved successfully'),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: colorScheme.primary,
                        foregroundColor: colorScheme.onPrimary,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text('Save Preset'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
