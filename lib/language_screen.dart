import 'package:flutter/material.dart';
import 'settings_controller.dart';

class LanguageScreen extends StatelessWidget {
  const LanguageScreen({super.key});

  final List<Map<String, String>> languages = const [
    {'code': 'uk', 'name': 'Українська', 'flag': '🇺🇦'},
    {'code': 'en', 'name': 'English', 'flag': '🇬🇧'},
    {'code': 'pl', 'name': 'Polski', 'flag': '🇵🇱'},
    {'code': 'de', 'name': 'Deutsch', 'flag': '🇩🇪'},
    {'code': 'es', 'name': 'Español', 'flag': '🇪🇸'},
  ];

  @override
  Widget build(BuildContext context) {
    final settings = SettingsController.instance;

    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: settings.backgroundColor,
          appBar: AppBar(
            backgroundColor: settings.backgroundColor,
            title: Text(
              settings.tr('language'),
              style: TextStyle(color: settings.textColor, fontWeight: FontWeight.bold),
            ),
            iconTheme: IconThemeData(color: settings.textColor),
            elevation: 0,
          ),
          body: ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 12),
            itemCount: languages.length,
            separatorBuilder: (_, __) => Divider(color: settings.textColor.withOpacity(0.08), height: 1),
            itemBuilder: (context, index) {
              final lang = languages[index];
              final isSelected = settings.currentLang == lang['code'];

              return ListTile(
                leading: Text(lang['flag']!, style: const TextStyle(fontSize: 26)),
                title: Text(
                  lang['name']!,
                  style: TextStyle(
                    color: isSelected ? settings.accentColor : settings.textColor,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  ),
                ),
                trailing: isSelected
                    ? Icon(Icons.check_circle_rounded, color: settings.accentColor)
                    : null,
                onTap: () {
                  settings.setLanguage(lang['code']!);
                },
              );
            },
          ),
        );
      },
    );
  }
}