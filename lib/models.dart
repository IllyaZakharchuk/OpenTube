import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

final ValueNotifier<String> appLanguageNotifier = ValueNotifier<String>('uk');
final ValueNotifier<String> appThemeNotifier = ValueNotifier<String>('dark');

class Song {
  final String title;
  final String path;
  final String artist;
  final bool isOnline;
  final String? artworkUrl;
  final String? trackId;

  Song({
    required this.title,
    required this.path,
    required this.artist,
    this.isOnline = false,
    this.artworkUrl,
    this.trackId,
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
      );
}

class CustomPlaylist {
  final String name;
  final List<Song> songs;

  CustomPlaylist({required this.name, required this.songs});

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
    'media': {'uk': 'Медіа', 'en': 'Media', 'ru': 'Медиа'},
    'search': {'uk': 'Пошук', 'en': 'Search', 'ru': 'Поиск'},
    'discover': {'uk': 'Інтернет', 'en': 'Discover', 'ru': 'Обзор'},
    'settings': {'uk': 'Налаштування', 'en': 'Settings', 'ru': 'Настройки'},
    'my_library': {'uk': 'Моя Медіатека', 'en': 'My Library', 'ru': 'Моя Медиатека'},
    'offline_tracks': {'uk': 'Офлайн треки', 'en': 'Offline Tracks', 'ru': 'Офлайн треки'},
    'my_playlists': {'uk': 'Мої плейлисти', 'en': 'My Playlists', 'ru': 'Мои плейлисты'},
    'now_playing': {'uk': 'ЗАРАЗ ГРАЄ', 'en': 'NOW PLAYING', 'ru': 'СЕЙЧАС ИГРАЕТ'},
    'add_local_tracks': {'uk': 'Додати локальні треки', 'en': 'Add local tracks', 'ru': 'Добавить локальные треки'},
    'create_new_playlist': {'uk': 'Створити новий плейлист', 'en': 'Create new playlist', 'ru': 'Создать новый плейлист'},
    'add_to_playlist': {'uk': 'Додати в плейлист', 'en': 'Add to playlist', 'ru': 'Добавить в плейлист'},
    'delete_from_storage': {'uk': 'Видалити з памʼяті', 'en': 'Delete from device', 'ru': 'Удалить из памяти'},
    'no_offline_tracks': {
      'uk': 'Офлайн-треків немає :(\nДодай файли або збережи з Інтернету',
      'en': 'No offline tracks :(\nAdd files or save from Web',
      'ru': 'Офлайн-треков нет :(\nДобавьте файлы или сохраните из интернета',
    },
    'no_playlists': {'uk': 'У тебе ще немає плейлистів :)', 'en': 'No playlists yet :)', 'ru': 'У вас еще нет плейлистов :)'},
    'search_library_hint': {'uk': 'Пошук по медіатеці...', 'en': 'Search library...', 'ru': 'Поиск по медиатеке...'},
    'search_web_hint': {'uk': 'Пошук треків (Lil Peep, PHARAOH, Slipknot)...', 'en': 'Search tracks...', 'ru': 'Поиск треков...'},
    'popular_in_ukraine': {'uk': '🔥 Популярне зараз', 'en': '🔥 Popular Now', 'ru': '🔥 Популярное сейчас'},
    'you_might_like': {'uk': '✨ Вам може сподобатись', 'en': '✨ You might like', 'ru': '✨ Вам может понравиться'},
    'save_offline': {'uk': 'Зберегти офлайн', 'en': 'Save offline', 'ru': 'Сохранить офлайн'},
    'tracks_count': {'uk': 'треків', 'en': 'tracks', 'ru': 'треков'},
    'language': {'uk': 'Мова інтерфейсу', 'en': 'App Language', 'ru': 'Язык интерфейса'},
    'appearance_and_language': {'uk': 'Вигляд та мова', 'en': 'Appearance & Language', 'ru': 'Вид и язык'},
    'theme': {'uk': 'Тема оформлення', 'en': 'Theme', 'ru': 'Тема оформления'},
    'theme_dark': {'uk': 'Темна (Dark)', 'en': 'Dark', 'ru': 'Темная'},
    'theme_oled': {'uk': 'AMOLED Чорна', 'en': 'AMOLED Black', 'ru': 'AMOLED Черная'},
    'theme_material3': {'uk': 'Material You (Dynamic)', 'en': 'Material You (Dynamic)', 'ru': 'Material You (Динамическая)'},
    'about_app': {'uk': 'Про додаток', 'en': 'About App', 'ru': 'О приложении'},
    'cancel': {'uk': 'Скасувати', 'en': 'Cancel', 'ru': 'Отмена'},
    'create': {'uk': 'Створити', 'en': 'Create', 'ru': 'Создать'},
    'local_track_artist': {'uk': 'Локальний файл', 'en': 'Local File', 'ru': 'Локальный файл'},
    'empty_search': {'uk': 'Нічого не знайдено :(', 'en': 'Nothing found :(', 'ru': 'Ничего не найдено :('},
  };

  static String tr(String key) {
    final lang = appLanguageNotifier.value;
    return _values[key]?[lang] ?? _values[key]?['uk'] ?? key;
  }
}

class MusicService {
  static const String baseUrl = 'http://130.61.92.248:8055';

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
        return list.map((item) => Song(
          title: item['title'] ?? '',
          path: '',
          artist: item['uploader'] ?? '',
          isOnline: true,
          artworkUrl: item['thumbnail'],
          trackId: item['id'],
        )).toList();
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
}