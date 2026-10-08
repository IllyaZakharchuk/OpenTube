import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum BgTheme { amoled, dark, white }

class SettingsController extends ChangeNotifier {
  static final SettingsController instance = SettingsController._internal();
  SettingsController._internal();

  String currentLang = 'uk';
  BgTheme bgTheme = BgTheme.amoled;
  Color accentColor = const Color(0xFFBB86FC);

  // --- Параметри плавного згасання / появи / зведення ---
  bool isFadeEnabled = true;
  int fadeInMs = 400;      // Час наростання (мс)
  int fadeOutMs = 400;     // Час згасання (мс)
  int crossfadeMs = 2000;  // Час змішування між треками (мс)

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

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();

    final savedLang = prefs.getString('settings_app_language');
    if (savedLang != null) {
      currentLang = savedLang;
    }

    final savedThemeIndex = prefs.getInt('settings_bg_theme_index');
    if (savedThemeIndex != null &&
        savedThemeIndex >= 0 &&
        savedThemeIndex < BgTheme.values.length) {
      bgTheme = BgTheme.values[savedThemeIndex];
    }

    final savedAccent = prefs.getInt('settings_accent_color_val');
    if (savedAccent != null) {
      accentColor = Color(savedAccent);
    }

    // Завантаження параметрів Fade / Crossfade
    isFadeEnabled = prefs.getBool('settings_is_fade_enabled') ?? true;
    fadeInMs = prefs.getInt('settings_fade_in_ms') ?? 400;
    fadeOutMs = prefs.getInt('settings_fade_out_ms') ?? 400;
    crossfadeMs = prefs.getInt('settings_crossfade_ms') ?? 2000;

    notifyListeners();
  }

  Future<void> setLanguage(String code) async {
    currentLang = code;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('settings_app_language', code);
  }

  Future<void> setBgTheme(BgTheme theme) async {
    bgTheme = theme;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('settings_bg_theme_index', theme.index);
  }

  Future<void> setAccentColor(Color color) async {
    accentColor = color;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('settings_accent_color_val', color.value);
  }

  // Збереження налаштувань Fade / Crossfade
  Future<void> setFadeSettings({
    bool? enabled,
    int? fadeIn,
    int? fadeOut,
    int? crossfade,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (enabled != null) {
      isFadeEnabled = enabled;
      await prefs.setBool('settings_is_fade_enabled', enabled);
    }
    if (fadeIn != null) {
      fadeInMs = fadeIn;
      await prefs.setInt('settings_fade_in_ms', fadeIn);
    }
    if (fadeOut != null) {
      fadeOutMs = fadeOut;
      await prefs.setInt('settings_fade_out_ms', fadeOut);
    }
    if (crossfade != null) {
      crossfadeMs = crossfade;
      await prefs.setInt('settings_crossfade_ms', crossfade);
    }
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
        'media': 'Медіатека',
        'discover': 'Пошук онлайн',
        'search': 'Пошук онлайн',
        'tracks': 'Треки',
        'playlists': 'Плейлисти',
        'add_files': 'Додати аудіофайли',
        'create_playlist': 'Створити плейлист',
        'create_new_playlist': 'Створити новий плейлист',
        'add_to_playlist': 'Додати до плейлиста',
        'delete_from_library': 'Видалити з медіатеки',
        'delete_playlist': 'Видалити плейлист',
        'no_playlists': 'Немає плейлистів',
        'empty_library': 'Медіатека порожня',
        'unknown_artist': 'Невідомий виконавець',
        'search_hint': 'Введіть назву треку або автора...',
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
        'create': 'Створити',
        // Fade & Crossfade
        'playback_settings': 'Відтворення та переходи',
        'smooth_transitions': 'Плавні переходи (Fade)',
        'fade_in_time': 'Час появи (Fade-In)',
        'fade_out_time': 'Час згасання (Fade-Out)',
        'crossfade_time': 'Змішування треків (Crossfade)',
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
        'media': 'Library',
        'discover': 'Discover',
        'search': 'Search Online',
        'tracks': 'Tracks',
        'playlists': 'Playlists',
        'add_files': 'Add Audio Files',
        'create_playlist': 'Create Playlist',
        'create_new_playlist': 'Create New Playlist',
        'add_to_playlist': 'Add to Playlist',
        'delete_from_library': 'Delete from Library',
        'delete_playlist': 'Delete Playlist',
        'no_playlists': 'No playlists yet',
        'empty_library': 'Library is empty',
        'unknown_artist': 'Unknown Artist',
        'search_hint': 'Enter track or artist name...',
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
        'create': 'Create',
        // Fade & Crossfade
        'playback_settings': 'Playback & Transitions',
        'smooth_transitions': 'Smooth transitions (Fade)',
        'fade_in_time': 'Fade-In Duration',
        'fade_out_time': 'Fade-Out Duration',
        'crossfade_time': 'Track Crossfade Duration',
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
        'media': 'Biblioteka',
        'discover': 'Szukaj online',
        'search': 'Szukaj online',
        'tracks': 'Utwory',
        'playlists': 'Playlisty',
        'add_files': 'Dodaj pliki audio',
        'create_playlist': 'Utwórz playlistę',
        'create_new_playlist': 'Utwórz nową playlistę',
        'add_to_playlist': 'Dodaj do playlisty',
        'delete_from_library': 'Usuń z biblioteki',
        'delete_playlist': 'Usuń playlistę',
        'no_playlists': 'Brak playlist',
        'empty_library': 'Biblioteka jest pusta',
        'unknown_artist': 'Nieznany wykonawca',
        'search_hint': 'Wpisz tytuł lub wykonawcę...',
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
        'create': 'Utwórz',
        // Fade & Crossfade
        'playback_settings': 'Odtwarzanie i przejścia',
        'smooth_transitions': 'Płynne przejścia (Fade)',
        'fade_in_time': 'Czas narastania (Fade-In)',
        'fade_out_time': 'Czas wyciszania (Fade-Out)',
        'crossfade_time': 'Płynne miksowanie (Crossfade)',
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
        'media': 'Bibliothek',
        'discover': 'Online suchen',
        'search': 'Online suchen',
        'tracks': 'Titel',
        'playlists': 'Wiedergabelisten',
        'add_files': 'Audiodateien hinzufügen',
        'create_playlist': 'Wiedergabeliste erstellen',
        'create_new_playlist': 'Neue Wiedergabeliste erstellen',
        'add_to_playlist': 'Zur Wiedergabeliste hinzufügen',
        'delete_from_library': 'Aus Bibliothek löschen',
        'delete_playlist': 'Wiedergabeliste löschen',
        'no_playlists': 'Keine Wiedergabelisten',
        'empty_library': 'Bibliothek ist leer',
        'unknown_artist': 'Unbekannter Künstler',
        'search_hint': 'Titel oder Künstler eingeben...',
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
        'create': 'Erstellen',
        // Fade & Crossfade
        'playback_settings': 'Wiedergabe & Übergänge',
        'smooth_transitions': 'Sanfte Übergänge (Fade)',
        'fade_in_time': 'Einblendzeit (Fade-In)',
        'fade_out_time': 'Ausblendzeit (Fade-Out)',
        'crossfade_time': 'Überblendzeit (Crossfade)',
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
        'media': 'Biblioteca',
        'discover': 'Buscar en línea',
        'search': 'Buscar en línea',
        'tracks': 'Canciones',
        'playlists': 'Listas de reproducción',
        'add_files': 'Añadir archivos de audio',
        'create_playlist': 'Crear lista de reproducción',
        'create_new_playlist': 'Crear nueva lista',
        'add_to_playlist': 'Añadir a la lista',
        'delete_from_library': 'Eliminar de la biblioteca',
        'delete_playlist': 'Eliminar lista',
        'no_playlists': 'No hay listas de reproducción',
        'empty_library': 'La biblioteca está vacía',
        'unknown_artist': 'Artista desconocido',
        'search_hint': 'Buscar canción o artista...',
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
        'create': 'Crear',
        // Fade & Crossfade
        'playback_settings': 'Reproducción y transiciones',
        'smooth_transitions': 'Transiciones suaves (Fade)',
        'fade_in_time': 'Tiempo de aparición (Fade-In)',
        'fade_out_time': 'Tiempo de desvanecimiento (Fade-Out)',
        'crossfade_time': 'Fundido cruzado (Crossfade)',
      },
    };

    return localizedValues[currentLang]?[key] ?? localizedValues['en']?[key] ?? key;
  }
}