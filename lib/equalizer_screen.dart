import 'package:flutter/material.dart';
import 'settings_controller.dart';
import 'equalizer_controller.dart';

class EqualizerScreen extends StatelessWidget {
  const EqualizerScreen({super.key});

  String _formatFreq(double freq) {
    if (freq >= 1000) {
      final k = freq / 1000;
      return k == k.roundToDouble() ? '${k.toInt()}k' : '${k.toStringAsFixed(1)}k';
    }
    return '${freq.toInt()}';
  }

  Widget _tuningRow(
    SettingsController settings,
    Color accent,
    bool enabled,
    String title,
    String valueText,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged,
  ) {
    return Column(
      children: [
        const Divider(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(title, style: TextStyle(color: settings.textColor, fontWeight: FontWeight.bold)),
            Text(valueText, style: TextStyle(color: accent, fontWeight: FontWeight.bold)),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          activeColor: accent,
          inactiveColor: settings.backgroundColor,
          onChanged: enabled ? onChanged : null,
        ),
      ],
    );
  }

  void _showSavePresetDialog(BuildContext context, EqualizerController eq, SettingsController settings) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: settings.surfaceColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          settings.tr('save_preset'),
          style: TextStyle(color: settings.textColor, fontWeight: FontWeight.bold),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: settings.textColor),
          decoration: InputDecoration(
            hintText: settings.tr('preset_name_hint'),
            hintStyle: TextStyle(color: settings.subTextColor),
            filled: true,
            fillColor: settings.backgroundColor,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(settings.tr('cancel'), style: TextStyle(color: settings.subTextColor)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: settings.accentColor),
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                eq.saveCurrentAsCustom(name);
                Navigator.pop(ctx);
              }
            },
            child: Text(
              settings.tr('save'),
              style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  void _showRenamePresetDialog(BuildContext context, EqualizerController eq, SettingsController settings, String oldName) {
    final controller = TextEditingController(text: oldName);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: settings.surfaceColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Змінити назву', style: TextStyle(color: settings.textColor, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: settings.textColor),
          decoration: InputDecoration(
            filled: true,
            fillColor: settings.backgroundColor,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(settings.tr('cancel'), style: TextStyle(color: settings.subTextColor)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: settings.accentColor),
            onPressed: () {
              final newName = controller.text.trim();
              if (newName.isNotEmpty) {
                eq.renameCustomPreset(oldName, newName);
                Navigator.pop(ctx);
              }
            },
            child: const Text('Зберегти', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showCustomPresetActionSheet(BuildContext context, EqualizerController eq, SettingsController settings, String name) {
    showModalBottomSheet(
      context: context,
      backgroundColor: settings.surfaceColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16.0, horizontal: 8.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: settings.subTextColor.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Text(
                name,
                style: TextStyle(color: settings.textColor, fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 12),
              ListTile(
                leading: Icon(Icons.download_rounded, color: settings.accentColor),
                title: Text('Зберегти у файл (Downloads)', style: TextStyle(color: settings.textColor, fontWeight: FontWeight.w600)),
                onTap: () async {
                  Navigator.pop(ctx);
                  final ok = await eq.exportCustomPresetToFile(name);
                  if (context.mounted && ok) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Пресет успішно експортовано у файл :)'), backgroundColor: Colors.green),
                    );
                  }
                },
              ),
              ListTile(
                leading: Icon(Icons.sync_rounded, color: settings.accentColor),
                title: Text('Перезаписати поточними налаштуваннями', style: TextStyle(color: settings.textColor, fontWeight: FontWeight.w600)),
                onTap: () {
                  Navigator.pop(ctx);
                  eq.overwriteCustomPreset(name);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Пресет "$name" оновлено :)'), backgroundColor: Colors.green),
                  );
                },
              ),
              ListTile(
                leading: Icon(Icons.edit_rounded, color: settings.accentColor),
                title: Text('Змінити назву', style: TextStyle(color: settings.textColor, fontWeight: FontWeight.w600)),
                onTap: () {
                  Navigator.pop(ctx);
                  _showRenamePresetDialog(context, eq, settings, name);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
                title: const Text('Видалити', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w600)),
                onTap: () {
                  Navigator.pop(ctx);
                  eq.deleteCustomPreset(name);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsController.instance;
    final eq = EqualizerController.instance;

    return AnimatedBuilder(
      animation: Listenable.merge([settings, eq]),
      builder: (context, _) {
        final accent = settings.accentColor;

        return Scaffold(
          backgroundColor: settings.backgroundColor,
          appBar: AppBar(
            backgroundColor: settings.backgroundColor,
            elevation: 0,
            leading: Navigator.canPop(context)
                ? IconButton(
                    icon: Icon(Icons.arrow_back_ios_new_rounded, color: settings.textColor),
                    onPressed: () => Navigator.pop(context),
                  )
                : null,
            title: Text(
              settings.tr('dsp_effects'),
              style: TextStyle(
                color: settings.textColor,
                fontFamily: 'sans-serif-rounded',
                fontWeight: FontWeight.w900,
              ),
            ),
            actions: [
              Switch(
                value: eq.isEnabled,
                activeColor: accent,
                onChanged: eq.toggleEnabled,
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 8.0),
                      child: ActionChip(
                        avatar: Icon(Icons.add_rounded, color: accent, size: 20),
                        label: Text(
                          settings.tr('save_preset'),
                          style: TextStyle(
                            color: settings.textColor,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'sans-serif-rounded',
                          ),
                        ),
                        backgroundColor: settings.surfaceColor,
                        onPressed: () => _showSavePresetDialog(context, eq, settings),
                      ),
                    ),
                    ...eq.allPresetNames.map((name) {
                      final isSelected = eq.currentPresetName == name;
                      final isCustom = eq.customPresets.containsKey(name);

                      final chip = InputChip(
                        label: Text(name),
                        selected: isSelected,
                        selectedColor: accent,
                        backgroundColor: settings.surfaceColor,
                        labelStyle: TextStyle(
                          color: isSelected ? Colors.black : settings.textColor,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'sans-serif-rounded',
                        ),
                        onSelected: (_) => eq.selectPreset(name),
                      );

                      return Padding(
                        padding: const EdgeInsets.only(right: 8.0),
                        child: isCustom
                            ? GestureDetector(
                                onLongPress: () => _showCustomPresetActionSheet(context, eq, settings, name),
                                child: chip,
                              )
                            : chip,
                      );
                    }),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // 10-смуговий еквалайзер
              Container(
                padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 8),
                decoration: BoxDecoration(
                  color: settings.surfaceColor,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  children: [
                    SizedBox(
                      height: 190,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: List.generate(eq.bands.length, (idx) {
                          final band = eq.bands[idx];
                          return Expanded(
                            child: Column(
                              children: [
                                Text(
                                  '${band.gainDb > 0 ? "+" : ""}${band.gainDb.toStringAsFixed(1)}',
                                  style: TextStyle(
                                    color: settings.subTextColor,
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Expanded(
                                  child: RotatedBox(
                                    quarterTurns: 3,
                                    child: SliderTheme(
                                      data: SliderThemeData(
                                        trackHeight: 3,
                                        activeTrackColor: accent,
                                        inactiveTrackColor: settings.backgroundColor,
                                        thumbColor: accent,
                                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                                        overlayShape: SliderComponentShape.noOverlay,
                                      ),
                                      child: Slider(
                                        value: band.gainDb,
                                        min: -10.0,
                                        max: 10.0,
                                        onChanged: eq.isEnabled
                                            ? (val) => eq.setBandGain(idx, val)
                                            : null,
                                      ),
                                    ),
                                  ),
                                ),
                                Text(
                                  _formatFreq(band.freq),
                                  style: TextStyle(
                                    color: settings.textColor,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Блок DSP ефектів
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: settings.surfaceColor,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          settings.tr('stereo_width'),
                          style: TextStyle(color: settings.textColor, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          '${(eq.stereoWidth * 100).toInt()}%',
                          style: TextStyle(color: accent, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    Slider(
                      value: eq.stereoWidth,
                      min: 0.0,
                      max: 2.0,
                      activeColor: accent,
                      inactiveColor: settings.backgroundColor,
                      onChanged: eq.isEnabled ? eq.setStereoWidth : null,
                    ),
                    const Divider(height: 16),

                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          settings.tr('reverb'),
                          style: TextStyle(color: settings.textColor, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          '${(eq.reverbMix * 100).toInt()}%',
                          style: TextStyle(color: accent, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    Slider(
                      value: eq.reverbMix,
                      min: 0.0,
                      max: 1.0,
                      activeColor: accent,
                      inactiveColor: settings.backgroundColor,
                      onChanged: eq.isEnabled ? eq.setReverbMix : null,
                    ),
                    const Divider(height: 16),

                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          settings.tr('exciter'),
                          style: TextStyle(color: settings.textColor, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          '${(eq.exciterAmount * 100).toInt()}%',
                          style: TextStyle(color: accent, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    Slider(
                      value: eq.exciterAmount,
                      min: 0.0,
                      max: 1.0,
                      activeColor: accent,
                      inactiveColor: settings.backgroundColor,
                      onChanged: eq.isEnabled ? eq.setExciter : null,
                    ),
                    const Divider(height: 16),

                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          settings.tr('tube_drive'),
                          style: TextStyle(color: settings.textColor, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          eq.tubeDrive > 0 ? '${eq.tubeDrive.toStringAsFixed(1)}x' : '0',
                          style: TextStyle(color: accent, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    Slider(
                      value: eq.tubeDrive,
                      min: 0.0,
                      max: 3.0,
                      activeColor: accent,
                      inactiveColor: settings.backgroundColor,
                      onChanged: eq.isEnabled ? eq.setTubeDrive : null,
                    ),

                    // Тонке налаштування
                    _tuningRow(settings, accent, eq.isEnabled, 'Удар бочки',
                        '${(eq.punchAmount * 100).toInt()}%', eq.punchAmount, 0.0, 1.0, eq.setPunchAmount),
                    _tuningRow(settings, accent, eq.isEnabled, 'Повітря (верхи)',
                        '+${eq.airDb.toStringAsFixed(1)} дБ', eq.airDb, 0.0, 8.0, eq.setAirDb),
                    _tuningRow(settings, accent, eq.isEnabled, 'Хвіст реверберації',
                        '${(eq.lateScale * 100).toInt()}%', eq.lateScale, 0.0, 1.0, eq.setLateScale),
                    _tuningRow(settings, accent, eq.isEnabled, 'Віддаленість боків',
                        '${(eq.centerCut * 100).toInt()}%', eq.centerCut, 0.0, 1.0, eq.setCenterCut),
                    _tuningRow(settings, accent, eq.isEnabled, 'Ехо',
                        '${(eq.echoAmount * 100).toInt()}%', eq.echoAmount, 0.0, 1.0, eq.setEchoAmount),
                    _tuningRow(settings, accent, eq.isEnabled, 'Преамп',
                        '${eq.preampDb > 0 ? "+" : ""}${eq.preampDb.toStringAsFixed(1)} дБ', eq.preampDb, -6.0, 6.0, eq.setPreampDb),
                    _tuningRow(settings, accent, eq.isEnabled, 'Стеля лімітера',
                        '${eq.limiterCeilingDb.toStringAsFixed(1)} дБ', eq.limiterCeilingDb, -6.0, 0.0, eq.setLimiterCeiling),
                    _tuningRow(settings, accent, eq.isEnabled, 'Реліз лімітера',
                        '${eq.limiterReleaseMs.toInt()} мс', eq.limiterReleaseMs, 20.0, 300.0, eq.setLimiterRelease),
                    _tuningRow(settings, accent, eq.isEnabled, 'Lookahead лімітера',
                        '${eq.limiterLookaheadMs.toStringAsFixed(1)} мс', eq.limiterLookaheadMs, 1.0, 10.0, eq.setLimiterLookahead),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        );
      },
    );
  }
}