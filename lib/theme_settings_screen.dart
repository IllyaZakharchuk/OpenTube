import 'package:flutter/material.dart';
import 'settings_controller.dart';

class ThemeSettingsScreen extends StatelessWidget {
  const ThemeSettingsScreen({super.key});

  final List<Color> accentPalette = const [
    Color(0xFFBB86FC), // Фіолетовий
    Color(0xFFFF3B30), // Червоний
    Color(0xFF00E5FF), // Бірюзовий
    Color(0xFF2979FF), // Синій
    Color(0xFF00E676), // Зелений
    Color(0xFFFF9100), // Помаранчевий
    Color(0xFFFF4081), // Рожевий
    Color(0xFFFFD600), // Жовтий
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
              settings.tr('theme'),
              style: TextStyle(color: settings.textColor, fontWeight: FontWeight.bold),
            ),
            iconTheme: IconThemeData(color: settings.textColor),
            elevation: 0,
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // 1. ОСНОВНИЙ КОЛІР (ФОН)
              Text(
                settings.tr('primary_color'),
                style: TextStyle(
                  color: settings.accentColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 12),
              _buildPrimaryColorCard(
                context,
                title: settings.tr('black_amoled'),
                subtitle: '#000000 (Максимальна економія)',
                theme: BgTheme.amoled,
                previewColor: Colors.black,
                current: settings.bgTheme,
              ),
              _buildPrimaryColorCard(
                context,
                title: settings.tr('dark'),
                subtitle: '#141414 (Темно-сірий графіт)',
                theme: BgTheme.dark,
                previewColor: const Color(0xFF141414),
                current: settings.bgTheme,
              ),
              _buildPrimaryColorCard(
                context,
                title: settings.tr('white'),
                subtitle: '#F6F7F9 (Світла тема)',
                theme: BgTheme.white,
                previewColor: const Color(0xFFF6F7F9),
                current: settings.bgTheme,
              ),

              const SizedBox(height: 28),

              // 2. ДРУГОРЯДНИЙ КОЛІР (АКЦЕНТ)
              Text(
                settings.tr('accent_color'),
                style: TextStyle(
                  color: settings.accentColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Кнопки, повзунки, виділення та активні елементи',
                style: TextStyle(color: settings.subTextColor, fontSize: 13),
              ),
              const SizedBox(height: 16),

              Wrap(
                spacing: 16,
                runSpacing: 16,
                children: accentPalette.map((color) {
                  final isSelected = settings.accentColor.value == color.value;
                  return GestureDetector(
                    onTap: () => settings.setAccentColor(color),
                    child: Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isSelected ? settings.textColor : Colors.transparent,
                          width: 3,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: color.withOpacity(0.4),
                            blurRadius: 8,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                      child: isSelected
                          ? Icon(Icons.check, color: _isColorLight(color) ? Colors.black : Colors.white)
                          : null,
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        );
      },
    );
  }

  bool _isColorLight(Color color) {
    return ThemeData.estimateBrightnessForColor(color) == Brightness.light;
  }

  Widget _buildPrimaryColorCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required BgTheme theme,
    required Color previewColor,
    required BgTheme current,
  }) {
    final settings = SettingsController.instance;
    final isSelected = current == theme;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: settings.surfaceColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSelected ? settings.accentColor : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: ListTile(
        onTap: () => settings.setBgTheme(theme),
        leading: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: previewColor,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.grey.shade600, width: 1),
          ),
        ),
        title: Text(title, style: TextStyle(color: settings.textColor, fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle, style: TextStyle(color: settings.subTextColor, fontSize: 12)),
        trailing: isSelected
            ? Icon(Icons.radio_button_checked, color: settings.accentColor)
            : Icon(Icons.radio_button_off, color: settings.subTextColor),
      ),
    );
  }
}