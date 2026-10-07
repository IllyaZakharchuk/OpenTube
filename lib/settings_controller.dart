import 'package:flutter/material.dart';

// Моделі для вибору кольору фону
enum BgTheme {
  amoled, // #000000
  dark,   // #121212
  white,  // #F8F9FA
}

class SettingsController extends ChangeNotifier {
  static final SettingsController instance = SettingsController._internal();
  SettingsController._internal();

  // 1. Мова
  String currentLang = 'uk';

  // 2. Кольори теми
  BgTheme bgTheme = BgTheme.amoled;
  Color accentColor = const Color(0xFFBB86FC); // Дефолтний акцент

  // Отримання реального кольору фону
  Color get backgroundColor {
    switch (bgTheme) {
      case BgTheme.amoled:
        return const Color(0xFF000000);
      case BgTheme.dark:
        return const Color(0xFF141414);
      case BgTheme.white:
        return const Color(0xFFF6F7F9);
    }
  }

  // Колір карток/полів
  Color get surfaceColor {
    switch (bgTheme) {
      case BgTheme.amoled:
        return const Color(0xFF111111);
      case BgTheme.dark:
        return const Color(0xFF222222);
      case BgTheme.white:
        return const Color(0xFFFFFFFF);
    }
  }

  // Колір головного тексту
  Color get textColor => bgTheme == BgTheme.white ? Colors.black87 : Colors.white;
  // Колір другорядного тексту
  Color get subTextColor => bgTheme == BgTheme.white ? Colors.black54 : Colors.white54;

  void setLanguage(String code) {
    currentLang = code;
    notifyListeners();
  }

  void setBgTheme(BgTheme theme) {
    bgTheme = theme;
    notifyListeners();
  }

  void setAccentColor(Color color) {
    accentColor = color;
    notifyListeners();
  }

  // Словник перекладів
  String tr(String key) {
    const Map<String, Map<String, String>> localizedValues = {
      'uk': {
        'settings': 'Налаштування',
        'theme': 'Тема оформлення',
        'theme_desc': 'Налаштування основного та другорядного кольорів',
        'language': 'Мова додатку',
        'primary_color': 'Основний колір (фон)',
        'accent_color': 'Другорядний колір (акцент)',
        'black_amoled': 'Чорний AMOLED',
        'dark': 'Темний (графіт)',
        'white': 'Білий',
        'library': 'Медіатека',
        'search': 'Пошук онлайн',
        'tracks': 'Треки',
        'search_hint': 'Введіть назву треку або автора...',
      },
      'en': {
        'settings': 'Settings',
        'theme': 'Appearance Theme',
        'theme_desc': 'Configure primary background and accent colors',
        'language': 'App Language',
        'primary_color': 'Primary Color (Background)',
        'accent_color': 'Secondary Color (Accent)',
        'black_amoled': 'Black AMOLED',
        'dark': 'Dark (Graphite)',
        'white': 'White',
        'library': 'Library',
        'search': 'Search Online',
        'tracks': 'Tracks',
        'search_hint': 'Enter track or artist name...',
      },
      'pl': {
        'settings': 'Ustawienia',
        'theme': 'Motyw wyglądu',
        'theme_desc': 'Konfiguracja koloru tła i akcentu',
        'language': 'Język aplikacji',
        'primary_color': 'Kolor podstawowy (Tło)',
        'accent_color': 'Kolor dodatkowy (Akcent)',
        'black_amoled': 'Czarny AMOLED',
        'dark': 'Ciemny (Grafit)',
        'white': 'Biały',
        'library': 'Biblioteka',
        'search': 'Szukaj online',
        'tracks': 'Utwory',
        'search_hint': 'Wpisz tytuł lub wykonawcę...',
      },
      'de': {
        'settings': 'Einstellungen',
        'theme': 'Design-Thema',
        'theme_desc': 'Hintergrund- und Akzentfarbe anpassen',
        'language': 'App-Sprache',
        'primary_color': 'Hauptfarbe (Hintergrund)',
        'accent_color': 'Zweitfarbe (Akzent)',
        'black_amoled': 'Schwarz AMOLED',
        'dark': 'Dunkel (Graphit)',
        'white': 'Weiß',
        'library': 'Bibliothek',
        'search': 'Online suchen',
        'tracks': 'Titel',
        'search_hint': 'Titel oder Künstler eingeben...',
      },
      'es': {
        'settings': 'Ajustes',
        'theme': 'Tema visual',
        'theme_desc': 'Configurar color de fondo y acento',
        'language': 'Idioma de la aplicación',
        'primary_color': 'Color primario (Fondo)',
        'accent_color': 'Color secundario (Acento)',
        'black_amoled': 'Negro AMOLED',
        'dark': 'Oscuro (Grafito)',
        'white': 'Blanco',
        'library': 'Biblioteca',
        'search': 'Buscar en línea',
        'tracks': 'Canciones',
        'search_hint': 'Buscar canción o artista...',
      },
    };

    return localizedValues[currentLang]?[key] ?? localizedValues['en']?[key] ?? key;
  }
}