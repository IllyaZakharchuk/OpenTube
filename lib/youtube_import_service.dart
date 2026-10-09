import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

class YoutubeImportParseFailure implements Exception {
  final String message;

  YoutubeImportParseFailure(this.message);

  @override
  String toString() => 'YoutubeImportParseFailure: $message';
}

/// Minimal YouTube playlist/import model used by the UI and the import service.
class YouTubeImportedTrack {
  final String? videoId;
  final String? playlistId;
  final String title;
  final String artist;
  final String? thumbnailUrl;
  final String source;

  const YouTubeImportedTrack({
    required this.videoId,
    required this.playlistId,
    required this.title,
    required this.artist,
    this.thumbnailUrl,
    this.source = 'yt',
  });

  Map<String, dynamic> toJson() => {
        'videoId': videoId,
        'playlistId': playlistId,
        'title': title,
        'artist': artist,
        'thumbnailUrl': thumbnailUrl,
        'source': source,
      };

  factory YouTubeImportedTrack.fromJson(Map<String, dynamic> json) =>
      YouTubeImportedTrack(
        videoId: json['videoId'] ?? json['id'],
        playlistId: json['playlistId'] ?? json['playlist_id'],
        title: json['title'] ?? '',
        artist: json['artist'] ?? json['uploader'] ?? '',
        thumbnailUrl: json['thumbnailUrl'] ?? json['thumbnail'],
        source: json['source'] ?? 'yt',
      );
}

/// Static helper to build stable keys for imported tracks.
class YoutubeImportKeys {
  static String trackKey(YouTubeImportedTrack track) {
    final id = track.videoId?.trim();
    if (id != null && id.isNotEmpty) return id;

    final artist = track.artist.trim().toLowerCase();
    final title = track.title.trim().toLowerCase();
    if (artist.isNotEmpty && title.isNotEmpty) {
      return '$artist|$title';
    }
    return track.title.trim().toLowerCase();
  }

  static String playlistKey({String? playlistId, String? title}) {
    final id = playlistId?.trim();
    if (id != null && id.isNotEmpty) return id;
    return (title ?? '').trim().toLowerCase();
  }
}

class YoutubeImportService {
  YoutubeImportService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const String defaultBaseUrl = MusicService.baseUrl;

  /// Extracts the YouTube playlist id (`list=...`) from a pasted URL.
  /// Handles extra query params (e.g. `&si=...`), fragments, missing
  /// scheme, surrounding text/punctuation and bare id paste.
  /// Returns null when the text is not a playlist link.
  static String? extractPlaylistId(String input) {
    var text = input.trim();
    if (text.isEmpty) return null;
    // Strip wrappers/punctuation from copy-paste or markdown links.
    text = text.replaceAll(
      RegExp("^\\s*[<\\(\\[\"']+|[\\s>\\)\\].,\"'']+\$"),
      '',
    );
    if (text.isEmpty) return null;

    // 1) Regex first: immune to extra params (&si=...), fragments (#...),
    //    missing scheme and surrounding text.
    final listMatch = RegExp(r'[?&]list=([A-Za-z0-9_-]+)').firstMatch(text);
    if (listMatch != null) {
      final id = (listMatch.group(1) ?? '').trim();
      if (id.isNotEmpty) return id;
    }

    // 2) Uri parsing (also retry with a scheme if the user pasted a
    //    scheme-less link like "music.youtube.com/playlist?list=...").
    final candidates = <String>[text];
    if (!text.contains('://') && text.contains('list=')) {
      candidates.add('https://$text');
    }
    for (final candidate in candidates) {
      final uri = Uri.tryParse(candidate);
      final fromQuery = uri?.queryParameters['list']?.trim();
      if (fromQuery != null && fromQuery.isNotEmpty) return fromQuery;
    }

    // 3) Bare id paste (e.g. "PLMC9KNkIncKtPzgY-5rmhvj7fax8fdxoj")
    //    or an id buried in surrounding text.
    final bare = RegExp(r'^[A-Za-z0-9_-]{10,}$').stringMatch(text);
    if (bare != null) return bare;
    return RegExp(r'\bPL[A-Za-z0-9_-]{10,}\b').stringMatch(text);
  }

  /// Direct call to GET /api/import/youtube/playlist.
  /// Returns null when the route is absent (HTTP 404) so the caller can
  /// fall back to /api/search; throws on other failures.
  Future<List<YouTubeImportedTrack>?> _fetchFromImportEndpoint({
    required String base,
    required String playlistId,
    required String url,
    required int limit,
  }) async {
    final uri = Uri.parse('$base/api/import/youtube/playlist').replace(
      queryParameters: {
        'playlist_id': playlistId,
        'url': url,
        'limit': limit.toString(),
      },
    );
    http.Response res;
    try {
      res = await _client.get(uri).timeout(const Duration(seconds: 45));
    } catch (_) {
      // Network failure -> let the /api/search fallback handle it.
      return null;
    }
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw YoutubeImportParseFailure(
        'YouTube import server returned HTTP ${res.statusCode}',
      );
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final List raw;
    if (decoded is List) {
      raw = decoded;
    } else if (decoded is Map) {
      final nested =
          decoded['tracks'] ?? decoded['results'] ?? decoded['items'];
      if (nested is! List) {
        throw YoutubeImportParseFailure('Unexpected import payload format');
      }
      raw = nested;
    } else {
      throw YoutubeImportParseFailure('Unexpected import payload format');
    }
    final items = <YouTubeImportedTrack>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final map = Map<String, dynamic>.from(entry);
      // Backend sends the playable id as "videoId" (also duplicated as "id").
      // Must map it to YouTubeImportedTrack.videoId, otherwise Song.trackId
      // ends up null and the player never calls /api/audio/stream.
      final rawVideoId = (map['videoId'] ?? map['id'] ?? map['video_id'])
          ?.toString()
          .trim();
      final videoId =
          (rawVideoId != null && rawVideoId.isNotEmpty) ? rawVideoId : null;
      final title = (map['title'] ?? map['name'] ?? '').toString().trim();
      final artist = (map['artist'] ?? map['uploader'] ?? '')
          .toString()
          .trim();
      // ignore: avoid_print
      print(
          '[YT Import] raw entry -> videoId=$videoId title="$title" artist="$artist"');
      if (title.isEmpty && videoId == null) continue;
      // Skip entries without a playable videoId: without it the stream URL
      // cannot be built and tapping the track would do nothing.
      if (videoId == null) {
        // ignore: avoid_print
        print('[YT Import] skip entry without videoId title="$title"');
        continue;
      }
      items.add(
        YouTubeImportedTrack(
          videoId: videoId,
          playlistId: (map['playlistId'] ?? playlistId).toString(),
          title: title.isEmpty ? videoId : title,
          artist: artist,
          thumbnailUrl: (map['thumbnail'] ??
                  map['thumbnailUrl'] ??
                  (videoId.isNotEmpty
                      ? 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg'
                      : null))
              ?.toString(),
          source: (map['source'] ?? 'yt').toString(),
        ),
      );
      if (items.length >= limit) break;
    }
    if (items.isEmpty) {
      throw YoutubeImportParseFailure('No importable YouTube items found');
    }
    return items;
  }

  /// Resolves one playable YouTube video id for a query via /api/search.
  Future<String?> _resolveVideoId(String query, {String? base}) async {
    final b = base ?? defaultBaseUrl;
    final uri = Uri.parse('$b/api/search')
        .replace(queryParameters: {'q': query, 'limit': '1'});
    final res =
        await _client.get(uri).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) return null;
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final List list = decoded is Map ? (decoded['results'] ?? []) : [];
    if (list.isEmpty) return null;
    final first = list.first;
    if (first is! Map) return null;
    final id = (first['id'] ?? first['videoId'] ?? '').toString().trim();
    return id.isEmpty ? null : id;
  }

  /// Fetches import-ready tracks for a YouTube / YouTube Music playlist.
  ///
  /// Primary path is the backend route `GET /api/import/youtube/playlist`
  /// (see `server/recommend.py`). If an older deploy lacks it (HTTP 404),
  /// we fall back to resolving queries via `/api/search`.
  Future<List<YouTubeImportedTrack>> fetchYouTubeTracks(
    String playlistId,
    String url, {
    int limit = 200,
    String? customBaseUrl,
  }) async {
    final base = customBaseUrl ?? defaultBaseUrl;
    final trimmedPid = playlistId.trim();
    final listId = extractPlaylistId(url) ??
        (trimmedPid.isEmpty ? url.trim() : trimmedPid);

    final direct = await _fetchFromImportEndpoint(
      base: base,
      playlistId: listId,
      url: url,
      limit: limit,
    );
    if (direct != null) return direct;

    final queries = await _discoverPlaylistQueries(
      playlistId: listId,
      url: url,
      limit: limit,
      base: base,
    );

    final items = <YouTubeImportedTrack>[];
    final seen = <String>{};
    for (final q in queries) {
      if (items.length >= limit) break;
      final query = q.trim();
      if (query.isEmpty || !seen.add(query.toLowerCase())) continue;
      String? videoId;
      try {
        videoId = await _resolveVideoId(query, base: base);
      } catch (_) {
        videoId = null;
      }
      if (videoId == null || videoId.isEmpty) continue;
      items.add(
        YouTubeImportedTrack(
          videoId: videoId,
          playlistId: listId,
          title: query,
          artist: '',
          thumbnailUrl: 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
          source: 'yt',
        ),
      );
    }

    if (items.isEmpty) {
      throw YoutubeImportParseFailure(
        'Не вдалося розпізнати плейлист за посиланням. '
        'Вставте коректне посилання з list= або перевірте зʼєднання із сервером.',
      );
    }

    return items;
  }

  /// Best-effort discovery of track queries for a pasted playlist URL.
  Future<List<String>> _discoverPlaylistQueries({
    required String playlistId,
    required String url,
    required int limit,
    String? base,
  }) async {
    final out = <String>[];
    final pasted = url.trim();
    if (pasted.isEmpty) return out;

    final uri = Uri.tryParse(pasted);
    final videoId = uri?.queryParameters['v']?.trim() ?? '';
    if (videoId.isNotEmpty) {
      out.add(videoId);
      return out;
    }

    final b = base ?? defaultBaseUrl;
    try {
      final searchUri = Uri.parse('$b/api/search').replace(
        queryParameters: {'q': pasted, 'limit': limit.clamp(1, 50).toString()},
      );
      final res =
          await _client.get(searchUri).timeout(const Duration(seconds: 20));
      if (res.statusCode == 200) {
        final decoded = jsonDecode(utf8.decode(res.bodyBytes));
        final List list = decoded is Map ? (decoded['results'] ?? []) : [];
        for (final item in list) {
          if (item is! Map) continue;
          final title = (item['title'] ?? '').toString().trim();
          final artist = (item['uploader'] ?? item['artist'] ?? '')
              .toString()
              .trim();
          final id = (item['id'] ?? item['videoId'] ?? '').toString().trim();
          final query = artist.isNotEmpty ? '$artist $title' : title;
          if (query.trim().isNotEmpty) out.add(query);
          if (id.isNotEmpty) out.add(id);
          if (out.length >= limit) break;
        }
      }
    } catch (_) {
      // Fall through to playlistId fallback below.
    }

    if (out.isEmpty && playlistId.isNotEmpty) {
      out.add(playlistId);
    }
    return out.take(limit).toList();
  }

  static List<CustomPlaylist> normalizeImportPayload(
    String playlistTitle,
    List<YouTubeImportedTrack> tracks, {
    required bool isOnline,
    String? playlistId,
  }) {
    final songs = <Song>[];
    final seen = <String>{};

    for (final track in tracks) {
      final key = YoutubeImportKeys.trackKey(track);
      if (seen.contains(key)) continue;
      seen.add(key);

      final title = track.title.isNotEmpty ? track.title : 'Unknown';
      final artist = track.artist.isNotEmpty ? track.artist : 'Unknown';

      // Backend sends the playable id as "videoId" (also duplicated as "id").
      // It must land in Song.trackId — _playSong builds
      // /api/audio/stream?id=<trackId> from it. Never fall back to
      // playlistId here: that would stream the wrong id.
      final rawId = track.videoId?.trim() ?? '';
      final resolvedId = rawId.isEmpty ? null : rawId;
      // ignore: avoid_print
      print(
          '[ImportMapper] title="$title" videoId=$resolvedId playlistId=${track.playlistId}');

      songs.add(
        Song(
          title: title,
          path: '',
          artist: artist,
          isOnline: true,
          artworkUrl: track.thumbnailUrl,
          trackId: resolvedId,
        ),
      );
    }

    return [
      CustomPlaylist(
        name: playlistTitle.isNotEmpty ? playlistTitle : 'Imported YouTube Playlist',
        songs: songs,
      ),
    ];
  }
}
