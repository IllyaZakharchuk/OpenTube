import 'package:flutter/material.dart';

enum BgTheme {
  amoled,
  dark,
  white,
}

class SettingsController extends ChangeNotifier {
  static final SettingsController instance = SettingsController._internal();
  SettingsController._internal();

  String currentLang = 'uk';
  BgTheme bgTheme = BgTheme.amoled;
  Color accentColor = const Color(0xFFBB86FC);

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

  Color get textColor => bgTheme == BgTheme.white ? Colors.black87 : Colors.white;
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
        // Еквалайзер & DSP
        'equalizer': 'Еквалайзер',
        'dsp_effects': 'DSP Ефекти',
        'enable_effects': 'Увімкнути обробку',
        'presets': 'Пресети',
        'custom_preset': 'Користувацький',
        'preamp': 'Передпідсилювач (Preamp)',
        'tube_drive': 'Ламповий драйв (Сатурація)',
        'exciter': 'Гармонічний ексайтер',
        'stereo_width': 'Ширина стереобази',
        'reverb': 'Просторова реверберація',
        'reset': 'Скинути',
        'save_preset': 'Зберегти пресет',
        'delete_preset': 'Видалити пресет',
        'preset_name_hint': 'Введіть назву пресету',
        'cancel': 'Скасувати',
        'save': 'Зберегти',
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
        // Equalizer & DSP
        'equalizer': 'Equalizer',
        'dsp_effects': 'DSP Effects',
        'enable_effects': 'Enable Processing',
        'presets': 'Presets',
        'custom_preset': 'Custom',
        'preamp': 'Preamp Gain',
        'tube_drive': 'Tube Drive (Saturation)',
        'exciter': 'Harmonic Exciter',
        'stereo_width': 'Stereo Width',
        'reverb': 'Spatial Reverb',
        'reset': 'Reset',
        'save_preset': 'Save Preset',
        'delete_preset': 'Delete Preset',
        'preset_name_hint': 'Enter preset name',
        'cancel': 'Cancel',
        'save': 'Save',
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
        // Korektor & DSP
        'equalizer': 'Korektor',
        'dsp_effects': 'Efekty DSP',
        'enable_effects': 'Włącz przetwarzanie',
        'presets': 'Profile',
        'custom_preset': 'Własny',
        'preamp': 'Wzmocnienie wstępne',
        'tube_drive': 'Ciepło lampowe',
        'exciter': 'Wzbudnik harmonicznych',
        'stereo_width': 'Szerokość stereo',
        'reverb': 'Pogłos przestrzenny',
        'reset': 'Resetuj',
        'save_preset': 'Zapisz profil',
        'delete_preset': 'Usuń profil',
        'preset_name_hint': 'Wpisz nazwę profilu',
        'cancel': 'Anuluj',
        'save': 'Zapisz',
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
        // Equalizer & DSP
        'equalizer': 'Equalizer',
        'dsp_effects': 'DSP-Effekte',
        'enable_effects': 'Verarbeitung aktivieren',
        'presets': 'Voreinstellungen',
        'custom_preset': 'Benutzerdefiniert',
        'preamp': 'Vorverstärkung',
        'tube_drive': 'Röhrenverzerrung',
        'exciter': 'Oberton-Exciter',
        'stereo_width': 'Stereobreite',
        'reverb': 'Raumhall',
        'reset': 'Zurücksetzen',
        'save_preset': 'Profil speichern',
        'delete_preset': 'Profil löschen',
        'preset_name_hint': 'Profilname eingeben',
        'cancel': 'Abbrechen',
        'save': 'Speichern',
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
        // Ecualizador & DSP
        'equalizer': 'Ecualizador',
        'dsp_effects': 'Efectos DSP',
        'enable_effects': 'Activar procesamiento',
        'presets': 'Preajustes',
        'custom_preset': 'Personalizado',
        'preamp': 'Preamplificador',
        'tube_drive': 'Saturación valvular',
        'exciter': 'Excitador armónico',
        'stereo_width': 'Amplitud estéreo',
        'reverb': 'Reverberación',
        'reset': 'Restablecer',
        'save_preset': 'Guardar preajuste',
        'delete_preset': 'Eliminar preajuste',
        'preset_name_hint': 'Nombre del preajuste',
        'cancel': 'Cancelar',
        'save': 'Guardar',
      },
    };

    return localizedValues[currentLang]?[key] ?? localizedValues['en']?[key] ?? key;
  }
}