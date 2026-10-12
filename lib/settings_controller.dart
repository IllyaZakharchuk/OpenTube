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
        // Settings categories
        'category_general': 'Загальні',
        'category_appearance': 'Вигляд',
        'category_playback': 'Відтворення',
        'category_equalizer': 'Еквалайзер та пресети',
        'disabled': 'Вимкнено',
        // About & changelog
        'about': 'Про додаток',
        'app_tagline': 'Сучасний відкритий музичний плеєр',
        'import_preset': 'Імпортувати пресет',
        'import_preset_desc': 'Завантажити пресет із .json файлу',
        'import_success': 'Пресет "{name}" успішно імпортовано та активовано :)',
        'import_error': 'Файл не обрано або сталася помилка читання',
        'changelog': 'Зміни',
        'release': 'Реліз',
        'release_notes': '• Розумні підказки пошуку (автоугадування)\n• Профіль виконавця: біографія та найкращі треки\n• Прогрес-бар у мініплеєрі\n• Масове виділення треків у медіатеці та плейлистах\n• Стоковий пресет еквалайзера',
        'support_project': 'Підтримати проєкт',
        'support_project_desc': 'Допоможіть розвитку OpenTube — донат підтримає нові функції та оновлення',
        'report_bug': 'Повідомити про баг',
        'report_bug_desc': 'Опиши проблему — повідомлення прийде розробнику в Telegram',
        'report_bug_hint': 'Що пішло не так? Опиши кроки, щоб відтворити проблему…',
        'report_bug_empty': 'Спочатку опиши проблему',
        'report_bug_sending': 'Надсилання…',
        'report_bug_success': 'Дякуємо! Баг-репорт надіслано ✅',
        'report_bug_error': 'Не вдалося надіслати. Перевір зʼєднання і спробуй ще раз',
        'send': 'Надіслати',
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
        // Settings categories
        'category_general': 'General',
        'category_appearance': 'Appearance',
        'category_playback': 'Playback',
        'category_equalizer': 'Equalizer & Presets',
        'disabled': 'Disabled',
        // About & changelog
        'about': 'About',
        'app_tagline': 'A modern open-source music player',
        'import_preset': 'Import preset',
        'import_preset_desc': 'Load a preset from a .json file',
        'import_success': 'Preset "{name}" imported and activated successfully :)',
        'import_error': 'No file selected or a read error occurred',
        'changelog': 'Changelog',
        'release': 'Release',
        'release_notes': '• Smart search suggestions\n• Artist profiles: biography & top tracks\n• Progress bar in the mini player\n• Multi-select track operations\n• Stock equalizer preset',
        'support_project': 'Support the project',
        'support_project_desc': 'Help OpenTube grow — a donation funds new features and updates',
        'report_bug': 'Report a bug',
        'report_bug_desc': 'Describe the issue — the message goes straight to the developer on Telegram',
        'report_bug_hint': 'What went wrong? Describe the steps to reproduce…',
        'report_bug_empty': 'Please describe the issue first',
        'report_bug_sending': 'Sending…',
        'report_bug_success': 'Thanks! Bug report sent ✅',
        'report_bug_error': 'Failed to send. Check your connection and try again',
        'send': 'Send',
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
        // Settings categories
        'category_general': 'Ogólne',
        'category_appearance': 'Wygląd',
        'category_playback': 'Odtwarzanie',
        'category_equalizer': 'Korektor i profile',
        'disabled': 'Wyłączone',
        // About & changelog
        'about': 'O aplikacji',
        'app_tagline': 'Nowoczesny otwartoźródłowy odtwarzacz muzyki',
        'import_preset': 'Importuj profil',
        'import_preset_desc': 'Wczytaj profil z pliku .json',
        'import_success': 'Profil "{name}" zaimportowano i aktywowano pomyślnie :)',
        'import_error': 'Nie wybrano pliku lub wystąpił błąd odczytu',
        'changelog': 'Zmiany',
        'release': 'Wydanie',
        'release_notes': '• Inteligentne podpowiedzi wyszukiwania\n• Profile wykonawcy: biografia i najlepsze utwory\n• Pasek postępu w mini odtwarzaczu\n• Zaznaczanie wielu utworów\n• Domyślny preset equalizera',
        'support_project': 'Wesprzyj projekt',
        'support_project_desc': 'Pomóż rozwijać OpenTube — darowizna sfinansuje nowe funkcje i aktualizacje',
        'report_bug': 'Zgłoś błąd',
        'report_bug_desc': 'Opisz problem — wiadomość trafi do dewelopera na Telegramie',
        'report_bug_hint': 'Co poszło nie tak? Opisz kroki, aby odtworzyć problem…',
        'report_bug_empty': 'Najpierw opisz problem',
        'report_bug_sending': 'Wysyłanie…',
        'report_bug_success': 'Dziękujemy! Zgłoszenie wysłane ✅',
        'report_bug_error': 'Nie udało się wysłać. Sprawdź połączenie i spróbuj ponownie',
        'send': 'Wyślij',
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
        // Settings categories
        'category_general': 'Allgemein',
        'category_appearance': 'Darstellung',
        'category_playback': 'Wiedergabe',
        'category_equalizer': 'Equalizer & Voreinstellungen',
        'disabled': 'Deaktiviert',
        // About & changelog
        'about': 'Über die App',
        'app_tagline': 'Ein moderner Open-Source-Musikplayer',
        'import_preset': 'Voreinstellung importieren',
        'import_preset_desc': 'Voreinstellung aus .json-Datei laden',
        'import_success': 'Voreinstellung "{name}" erfolgreich importiert und aktiviert :)',
        'import_error': 'Keine Datei ausgewählt oder Lesefehler',
        'changelog': 'Änderungen',
        'release': 'Release',
        'release_notes': '• Intelligente Suchvorschläge\n• Künstlerprofile: Biografie & Top-Titel\n• Fortschrittsbalken im Mini-Player\n• Mehrfachauswahl von Titeln\n• Standard-Equalizer-Preset',
        'support_project': 'Projekt unterstützen',
        'support_project_desc': 'Helfen Sie, OpenTube weiterzuentwickeln — Spende für neue Funktionen & Updates',
        'report_bug': 'Fehler melden',
        'report_bug_desc': 'Beschreibe das Problem — die Nachricht geht direkt an den Entwickler auf Telegram',
        'report_bug_hint': 'Was ist schiefgelaufen? Beschreibe die Schritte zur Reproduktion…',
        'report_bug_empty': 'Bitte beschreibe zuerst das Problem',
        'report_bug_sending': 'Wird gesendet…',
        'report_bug_success': 'Danke! Fehlerbericht gesendet ✅',
        'report_bug_error': 'Senden fehlgeschlagen. Prüfe die Verbindung und versuche es erneut',
        'send': 'Senden',
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
        // Settings categories
        'category_general': 'General',
        'category_appearance': 'Apariencia',
        'category_playback': 'Reproducción',
        'category_equalizer': 'Ecualizador y preajustes',
        'disabled': 'Desactivado',
        // About & changelog
        'about': 'Acerca de',
        'app_tagline': 'Un reproductor de música moderno y de código abierto',
        'import_preset': 'Importar preajuste',
        'import_preset_desc': 'Cargar un preajuste desde un archivo .json',
        'import_success': 'Preajuste "{name}" importado y activado correctamente :)',
        'import_error': 'No se seleccionó ningún archivo o hubo un error de lectura',
        'changelog': 'Cambios',
        'release': 'Lanzamiento',
        'release_notes': '• Sugerencias inteligentes de búsqueda\n• Perfiles de artista: biografía y mejores canciones\n• Barra de progreso en el mini reproductor\n• Selección múltiple de pistas\n• Preset de ecualizador predeterminado',
        'support_project': 'Apoyar el proyecto',
        'support_project_desc': 'Ayuda a hacer crecer OpenTube — una donación financia nuevas funciones y actualizaciones',
        'report_bug': 'Informar de un error',
        'report_bug_desc': 'Describe el problema — el mensaje llega al desarrollador en Telegram',
        'report_bug_hint': '¿Qué salió mal? Describe los pasos para reproducirlo…',
        'report_bug_empty': 'Primero describe el problema',
        'report_bug_sending': 'Enviando…',
        'report_bug_success': '¡Gracias! Informe enviado ✅',
        'report_bug_error': 'No se pudo enviar. Revisa tu conexión e inténtalo de nuevo',
        'send': 'Enviar',
      },
    };

    return localizedValues[currentLang]?[key] ?? localizedValues['en']?[key] ?? key;
  }
}