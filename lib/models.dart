import 'settings_controller.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

final ValueNotifier<String> appLanguageNotifier = ValueNotifier<String>('uk');
final ValueNotifier<String> appThemeNotifier = ValueNotifier<String>('dark');

class Song {
  String title;
  final String path;
  String artist;
  final bool isOnline;
  final String? artworkUrl;
  final String? trackId;
  int playCount;

  Song({
    required this.title,
    required this.path,
    required this.artist,
    this.isOnline = false,
    this.artworkUrl,
    this.trackId,
    this.playCount = 0,
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'path': path,
        'artist': artist,
        'isOnline': isOnline,
        'artworkUrl': artworkUrl,
        'trackId': trackId,
      };

  factory Song.fromJson(Map<String, dynamic> json) => Song(
        title: json['title'] ?? '',
        path: json['path'] ?? '',
        artist: json['artist'] ?? '',
        isOnline: json['isOnline'] ?? false,
        artworkUrl: json['artworkUrl'] ?? json['thumbnail'],
        trackId: json['trackId'] ?? json['id'] ?? json['videoId'],
        playCount: (json['playCount'] as num?)?.toInt() ?? 0,
      );

  /// Creates a copy of this song, overriding only the provided fields.
  Song copyWith({
    String? title,
    String? path,
    String? artist,
    bool? isOnline,
    String? artworkUrl,
    String? trackId,
    int? playCount,
  }) {
    return Song(
      title: title ?? this.title,
      path: path ?? this.path,
      artist: artist ?? this.artist,
      isOnline: isOnline ?? this.isOnline,
      artworkUrl: artworkUrl ?? this.artworkUrl,
      trackId: trackId ?? this.trackId,
      playCount: playCount ?? this.playCount,
    );
  }

  /// Sorts `songs` in place (descending by playCount) and returns it.
  static List<Song> sortByPlayCount(List<Song> songs) {
    final sorted = List<Song>.from(songs);
    sorted.sort((a, b) {
      final aCount = a.playCount;
      final bCount = b.playCount;
      return bCount.compareTo(aCount);
    });
    return sorted;
  }
}

class CustomPlaylist {
  String name;
  final List<Song> songs;

  CustomPlaylist({
    required this.name,
    required this.songs,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'songs': songs.map((s) => s.toJson()).toList(),
      };

  factory CustomPlaylist.fromJson(Map<String, dynamic> json) => CustomPlaylist(
        name: json['name'] ?? '',
        songs: (json['songs'] as List? ?? [])
            .map((s) => Song.fromJson(s as Map<String, dynamic>))
            .toList(),
      );
}

class AppLocale {
  static const Map<String, Map<String, String>> _values = {
    'media': {
      'uk': 'Медіа',
      'en': 'Media',
      'pl': 'Media',
      'de': 'Medien',
      'es': 'Medios',
    },
    'search': {
      'uk': 'Пошук',
      'en': 'Search',
      'pl': 'Szukaj',
      'de': 'Suche',
      'es': 'Buscar',
    },
    'discover': {
      'uk': 'Інтернет',
      'en': 'Discover',
      'pl': 'Odkrywaj',
      'de': 'Entdecken',
      'es': 'Descubrir',
    },
    'settings': {
      'uk': 'Налаштування',
      'en': 'Settings',
      'pl': 'Ustawienia',
      'de': 'Einstellungen',
      'es': 'Ajustes',
    },
    'my_library': {
      'uk': 'Моя Медіатека',
      'en': 'My Library',
      'pl': 'Moja Biblioteka',
      'de': 'Meine Bibliothek',
      'es': 'Mi Biblioteca',
    },
    'offline_tracks': {
      'uk': 'Офлайн треки',
      'en': 'Offline Tracks',
      'pl': 'Utwory offline',
      'de': 'Offline-Titel',
      'es': 'Pistas sin conexión',
    },
    'my_playlists': {
      'uk': 'Мої плейлисти',
      'en': 'My Playlists',
      'pl': 'Moje playlisty',
      'de': 'Meine Playlists',
      'es': 'Mis listas',
    },
    'now_playing': {
      'uk': 'ЗАРАЗ ГРАЄ',
      'en': 'NOW PLAYING',
      'pl': 'TERAZ ODTWARZANE',
      'de': 'JETZT LÄUFT',
      'es': 'REPRODUCIENDO',
    },
    'add_local_tracks': {
      'uk': 'Додати локальні треки',
      'en': 'Add local tracks',
      'pl': 'Dodaj utwory lokalne',
      'de': 'Lokale Titel hinzufügen',
      'es': 'Añadir pistas locales',
    },
    'create_new_playlist': {
      'uk': 'Створити новий плейлист',
      'en': 'Create new playlist',
      'pl': 'Utwórz nową playlistę',
      'de': 'Neue Playlist erstellen',
      'es': 'Crear nueva lista',
    },
    'add_to_playlist': {
      'uk': 'Додати в плейлист',
      'en': 'Add to playlist',
      'pl': 'Dodaj do playlisty',
      'de': 'Zur Playlist hinzufügen',
      'es': 'Añadir a la lista',
    },
    'delete_from_storage': {
      'uk': 'Видалити з памʼяті',
      'en': 'Delete from device',
      'pl': 'Usuń z urządzenia',
      'de': 'Vom Gerät löschen',
      'es': 'Eliminar del dispositivo',
    },
    'no_offline_tracks': {
      'uk': 'Офлайн-треків немає :(\nДодай файли або збережи з Інтернету',
      'en': 'No offline tracks :(\nAdd files or save from Web',
      'pl': 'Brak utworów offline :(\nDodaj pliki lub pobierz z sieci',
      'de': 'Keine Offline-Titel :(\nDateien hinzufügen oder herunterladen',
      'es':
          'Sin canciones sin conexión :(\nAñade archivos o descarga de la red',
    },
    'no_playlists': {
      'uk': 'У тебе ще немає плейлистів :)',
      'en': 'No playlists yet :)',
      'pl': 'Nie masz jeszcze playlist :)',
      'de': 'Noch keine Playlists vorhanden :)',
      'es': 'Aún no tienes listas :)',
    },
    'search_library_hint': {
      'uk': 'Пошук по медіатеці...',
      'en': 'Search library...',
      'pl': 'Szukaj w bibliotece...',
      'de': 'In Bibliothek suchen...',
      'es': 'Buscar en la biblioteca...',
    },
    'search_web_hint': {
      'uk': 'Пошук треків (Lil Peep, PHARAOH, Slipknot)...',
      'en': 'Search tracks...',
      'pl': 'Szukaj utworów...',
      'de': 'Titel suchen...',
      'es': 'Buscar canciones...',
    },
    'popular_in_ukraine': {
      'uk': '🔥 Популярне зараз',
      'en': '🔥 Popular Now',
      'pl': '🔥 Popularne teraz',
      'de': '🔥 Beliebt jetzt',
      'es': '🔥 Popular ahora',
    },
    'you_might_like': {
      'uk': '✨ Вам може сподобатись',
      'en': '✨ You might like',
      'pl': '✨ Może Ci się spodobać',
      'de': '✨ Das könnte dir gefallen',
      'es': '✨ Te podría gustar',
    },
    'save_offline': {
      'uk': 'Зберегти офлайн',
      'en': 'Save offline',
      'pl': 'Zapisz offline',
      'de': 'Offline speichern',
      'es': 'Guardar sin conexión',
    },
    'tracks_count': {
      'uk': 'треків',
      'en': 'tracks',
      'pl': 'utworów',
      'de': 'Titel',
      'es': 'pistas',
    },
    'language': {
      'uk': 'Мова інтерфейсу',
      'en': 'App Language',
      'pl': 'Język aplikacji',
      'de': 'App-Sprache',
      'es': 'Idioma de la aplicación',
    },
    'appearance_and_language': {
      'uk': 'Вигляд та мова',
      'en': 'Appearance & Language',
      'pl': 'Wygląd i język',
      'de': 'Design & Sprache',
      'es': 'Apariencia e idioma',
    },
    'theme': {
      'uk': 'Тема оформлення',
      'en': 'Theme',
      'pl': 'Motyw',
      'de': 'Design-Thema',
      'es': 'Tema',
    },
    'about_app': {
      'uk': 'Про додаток',
      'en': 'About App',
      'pl': 'O aplikacji',
      'de': 'Über die App',
      'es': 'Acerca de la app',
    },
    'cancel': {
      'uk': 'Скасувати',
      'en': 'Cancel',
      'pl': 'Anuluj',
      'de': 'Abbrechen',
      'es': 'Cancelar',
    },
    'create': {
      'uk': 'Створити',
      'en': 'Create',
      'pl': 'Utwórz',
      'de': 'Erstellen',
      'es': 'Crear',
    },
    'local_track_artist': {
      'uk': 'Локальний файл',
      'en': 'Local File',
      'pl': 'Plik lokalny',
      'de': 'Lokale Datei',
      'es': 'Archivo local',
    },
    'empty_search': {
      'uk': 'Нічого не знайдено :(',
      'en': 'Nothing found :(',
      'pl': 'Nic nie znaleziono :(',
      'de': 'Nichts gefunden :(',
      'es': 'No se encontró nada :(',
    },
    'all_music': {
      'uk': 'Вся музика',
      'en': 'All Music',
      'pl': 'Wszystka muzyka',
      'de': 'Alle Musik',
      'es': 'Toda la música',
    },
    'artists': {
      'uk': 'Виконавці',
      'en': 'Artists',
      'pl': 'Wykonawcy',
      'de': 'Künstler',
      'es': 'Artistas',
    },
    'playlists': {
      'uk': 'Плейлисти',
      'en': 'Playlists',
      'pl': 'Playlisty',
      'de': 'Wiedergabelisten',
      'es': 'Listas de reproducción',
    },
    'in_storage': {
      'uk': 'у памʼяті',
      'en': 'in storage',
      'pl': 'w pamięci',
      'de': 'im Speicher',
      'es': 'en memoria',
    },
    'playlists_count': {
      'uk': 'списків відтворення',
      'en': 'playlists',
      'pl': 'list odtwarzania',
      'de': 'Wiedergabelisten',
      'es': 'listas',
    },
    'artists_count': {
      'uk': 'артистів',
      'en': 'artists',
      'pl': 'artystów',
      'de': 'Künstler',
      'es': 'artistas',
    },
    'back': {
      'uk': 'Назад',
      'en': 'Back',
      'pl': 'Wstecz',
      'de': 'Zurück',
      'es': 'Atrás',
    },
  };

  static String tr(String key) {
    final lang = SettingsController.instance.currentLang;
    if (_values.containsKey(key)) {
      return _values[key]?[lang] ?? _values[key]?['uk'] ?? key;
    }
    return SettingsController.instance.tr(key);
  }
}

class MusicService {
  static const String baseUrl = 'http://130.61.92.248:8055';

  /// Last.fm track.getSimilar / artist.getSimilar. Empty = skip client Last.fm
  /// (the Oracle /api/recommend still uses LASTFM_API_KEY on the server).
  static const String lastFmApiKey = String.fromEnvironment('LASTFM_API_KEY');

  static Future<List<Song>> search(String query, {int limit = 20}) async {
    try {
      final uri = Uri.parse('$baseUrl/api/search').replace(queryParameters: {
        'q': query,
        'limit': limit.toString(),
      });
      final res = await http.get(uri);
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final List list = data['results'] ?? [];
        return list
            .map((item) => Song(
                  title: item['title'] ?? '',
                  path: '',
                  artist: item['uploader'] ?? '',
                  isOnline: true,
                  artworkUrl: item['thumbnail'],
                  trackId: item['id'],
                ))
            .toList();
      }
      return [];
    } catch (e) {
      debugPrint('Search error: $e');
      return [];
    }
  }

  static Future<List<Song>> getTrending() async {
    return search('Ukrainian music hits топ треки', limit: 12);
  }

  static Future<List<Song>> getRecommendations() async {
    return search('Lil Peep PHARAOH Slipknot Ghostemane', limit: 15);
  }

  static String getStreamUrl(String trackId) {
    return '$baseUrl/api/audio/stream?id=$trackId';
  }

  static List<Song> _songsFromResults(dynamic data) {
    final List list =
        data is List ? data : (data['results'] ?? data['tracks'] ?? []);
    return list.map((item) {
      final map = item as Map<String, dynamic>;
      return Song(
        title: map['title'] ?? '',
        path: '',
        artist: map['uploader'] ?? map['artist'] ?? '',
        isOnline: true,
        artworkUrl: map['thumbnail'] ?? map['artworkUrl'],
        trackId: map['id'] ?? map['videoId'] ?? map['trackId'],
      );
    }).toList();
  }

  static Future<List<Song>> getRadio(String videoId, {int limit = 15}) async {
    try {
      final uri = Uri.parse('$baseUrl/api/radio').replace(queryParameters: {
        'id': videoId,
        'limit': limit.toString(),
      });
      final res = await http.get(uri).timeout(const Duration(seconds: 20));
      if (res.statusCode == 200) {
        return _songsFromResults(jsonDecode(utf8.decode(res.bodyBytes)));
      }
    } catch (e) {
      debugPrint('Radio error: $e');
    }
    return [];
  }

  /// YouTube Music radio + Last.fm + Deezer, ranked on the Oracle box.
  static Future<List<Song>> fetchPersonalized({
    required List<Map<String, dynamic>> seeds,
    required Set<String> excludeIds,
    int limit = 20,
  }) async {
    final uri = Uri.parse('$baseUrl/api/recommend');
    final res = await http
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'seeds': seeds,
            'exclude_ids': excludeIds.toList(),
            'limit': limit,
          }),
        )
        .timeout(const Duration(seconds: 45));
    if (res.statusCode != 200) {
      throw Exception('recommend HTTP ${res.statusCode}');
    }
    return _songsFromResults(jsonDecode(utf8.decode(res.bodyBytes)));
  }

  static Future<List<Song>> lastFmSimilarTracks({
    required String artist,
    required String title,
    int limit = 8,
  }) async {
    if (lastFmApiKey.isEmpty || artist.trim().isEmpty || title.trim().isEmpty) {
      return [];
    }
    try {
      final uri = Uri.parse('https://ws.audioscrobbler.com/2.0/').replace(
        queryParameters: {
          'method': 'track.getsimilar',
          'artist': artist,
          'track': title,
          'api_key': lastFmApiKey,
          'format': 'json',
          'limit': '$limit',
        },
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return [];
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      final List tracks =
          (((data as Map?)?['similartracks'] as Map?)?['track'] as List?) ?? [];
      final out = <Song>[];
      for (final t in tracks.take(limit)) {
        final name = (t as Map)['name'] as String? ?? '';
        final art = (t['artist'] as Map?)?['name'] as String? ?? '';
        if (name.isEmpty || art.isEmpty) continue;
        final found = await search('$art $name', limit: 1);
        out.addAll(found);
      }
      return out;
    } catch (e) {
      debugPrint('Last.fm similar error: $e');
      return [];
    }
  }

  /// Deezer has no key. We search the track, then related artists, then YouTube.
  static Future<List<Song>> deezerSimilar({
    required String artist,
    required String title,
  }) async {
    try {
      final q = Uri.encodeQueryComponent('$artist $title');
      final searchRes = await http
          .get(Uri.parse('https://api.deezer.com/search/track?q=$q'))
          .timeout(const Duration(seconds: 12));
      if (searchRes.statusCode != 200) return [];
      final data = jsonDecode(utf8.decode(searchRes.bodyBytes));
      final List tracks = data['data'] ?? [];
      if (tracks.isEmpty) return [];
      final artistId = tracks.first['artist']?['id'];
      if (artistId == null) return [];

      final relRes = await http
          .get(Uri.parse('https://api.deezer.com/artist/$artistId/related'))
          .timeout(const Duration(seconds: 12));
      if (relRes.statusCode != 200) return [];
      final rel = jsonDecode(utf8.decode(relRes.bodyBytes));
      final List artists = rel['data'] ?? [];
      final out = <Song>[];
      for (final a in artists.take(3)) {
        final name = a['name'] as String? ?? '';
        if (name.isEmpty) continue;
        out.addAll(await search(name, limit: 4));
      }
      return out;
    } catch (e) {
      debugPrint('Deezer similar error: $e');
      return [];
    }
  }
}
