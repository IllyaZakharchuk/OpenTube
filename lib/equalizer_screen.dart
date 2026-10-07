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
              'DSP Studio Engine',
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
                  children: eq.presets.keys.map((name) {
                    final isSelected = eq.currentPresetName == name;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8.0),
                      child: ChoiceChip(
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
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 16),

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
                                  '${band.gainDb > 0 ? "+" : ""}${band.gainDb.toStringAsFixed(0)}',
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
                          'Ширина сцени (Mid/Side)',
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
                      min: 0.5,
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
                          'Повітря & Блиск (Exciter)',
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
                          'Лампове насичення (Drive)',
                          style: TextStyle(color: settings.textColor, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          eq.tubeDrive > 0 ? '${eq.tubeDrive.toStringAsFixed(1)}x' : 'Вимк',
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