import 'package:flutter/material.dart';
import 'settings_controller.dart';
import 'models.dart';

class PlaybackSettingsScreen extends StatelessWidget {
  const PlaybackSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = SettingsController.instance;

    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) {
        final accent = settings.accentColor;

        return Scaffold(
          backgroundColor: settings.backgroundColor,
          appBar: AppBar(
            backgroundColor: settings.backgroundColor,
            elevation: 0,
            leading: IconButton(
              icon: Icon(Icons.arrow_back_ios_new_rounded, color: settings.textColor),
              onPressed: () => Navigator.pop(context),
            ),
            title: Text(
              AppLocale.tr('playback_settings'),
              style: TextStyle(
                color: settings.textColor,
                fontWeight: FontWeight.w900,
                fontSize: 20,
                fontFamily: 'sans-serif-rounded',
              ),
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            children: [
              Container(
                decoration: BoxDecoration(
                  color: settings.surfaceColor,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: SwitchListTile(
                  activeColor: accent,
                  title: Text(
                    AppLocale.tr('smooth_transitions'),
                    style: TextStyle(
                      color: settings.textColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                  value: settings.isFadeEnabled,
                  onChanged: (val) => settings.setFadeSettings(enabled: val),
                ),
              ),
              if (settings.isFadeEnabled) ...[
                const SizedBox(height: 20),
                Text(
                  AppLocale.tr('fade_in_time'),
                  style: TextStyle(
                    color: accent,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: settings.surfaceColor,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Час наростання', style: TextStyle(color: settings.textColor)),
                          Text(
                            '${(settings.fadeInMs / 1000).toStringAsFixed(1)} c',
                            style: TextStyle(color: accent, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      Slider(
                        value: settings.fadeInMs.toDouble(),
                        min: 100,
                        max: 3000,
                        divisions: 29,
                        activeColor: accent,
                        onChanged: (val) => settings.setFadeSettings(fadeIn: val.round()),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  AppLocale.tr('fade_out_time'),
                  style: TextStyle(
                    color: accent,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: settings.surfaceColor,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Час затухання', style: TextStyle(color: settings.textColor)),
                          Text(
                            '${(settings.fadeOutMs / 1000).toStringAsFixed(1)} c',
                            style: TextStyle(color: accent, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      Slider(
                        value: settings.fadeOutMs.toDouble(),
                        min: 100,
                        max: 3000,
                        divisions: 29,
                        activeColor: accent,
                        onChanged: (val) => settings.setFadeSettings(fadeOut: val.round()),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  AppLocale.tr('crossfade_time'),
                  style: TextStyle(
                    color: accent,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: settings.surfaceColor,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Зведення треків', style: TextStyle(color: settings.textColor)),
                          Text(
                            '${(settings.crossfadeMs / 1000).toStringAsFixed(1)} c',
                            style: TextStyle(color: accent, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      Slider(
                        value: settings.crossfadeMs.toDouble(),
                        min: 500,
                        max: 5000,
                        divisions: 18,
                        activeColor: accent,
                        onChanged: (val) => settings.setFadeSettings(crossfade: val.round()),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}