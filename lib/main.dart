import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:audiotags/audiotags.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'language_screen.dart';
import 'theme_settings_screen.dart';
import 'settings_controller.dart';
import 'models.dart';
import 'audio_handler.dart';
import 'player_screen.dart';
import 'equalizer_screen.dart';
import 'equalizer_controller.dart';
import 'dsp_engine.dart';
import 'playback_settings_screen.dart';
import 'listen_tracker.dart';
import 'recommendation_engine.dart';
import 'youtube_import_dialog.dart';
import 'youtube_import_service.dart';
import 'artist_profile.dart';

AudioHandler? audioHandler;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Завантажуємо збережену мову, тему та акцентний колір з диска
  await SettingsController.instance.loadSettings();
  
  // Запитуємо дозвіл на сповіщення при старті
  await Permission.notification.request();

  try {
    audioHandler = await initAudioService();
  } catch (e, stack) {
    debugPrint('--> [AudioService CRASH]: $e\n$stack');
  }

  runApp(const OpenTubeApp());
}

class OpenTubeApp extends StatelessWidget {
  const OpenTubeApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = SettingsController.instance;

    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) {
        final isLight = settings.bgTheme == BgTheme.white;

        return MaterialApp(
          title: 'OpenTube',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            brightness: isLight ? Brightness.light : Brightness.dark,
            scaffoldBackgroundColor: settings.backgroundColor,
            primaryColor: settings.accentColor,
            colorScheme: ColorScheme.fromSeed(
              seedColor: settings.accentColor,
              brightness: isLight ? Brightness.light : Brightness.dark,
              surface: settings.surfaceColor,
              primary: settings.accentColor,
            ),
            progressIndicatorTheme: ProgressIndicatorThemeData(
              color: settings.accentColor,
            ),
            cardTheme: CardTheme(
              color: isLight
                  ? Colors.black.withOpacity(0.04)
                  : Colors.white.withOpacity(0.05),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          home: const MainContainerScreen(),
        );
      },
    );
  }
}

class MainContainerScreen extends StatefulWidget {
  const MainContainerScreen({super.key});

  @override
  State<MainContainerScreen> createState() => _MainContainerScreenState();
}

class _MainContainerScreenState extends State<MainContainerScreen>
    with WidgetsBindingObserver {
  int _currentIndex = 0;
  List<Song> librarySongs = [];
  List<CustomPlaylist> userPlaylists = [];
  bool isLoadingLibrary = true;
  bool _isShuffle = false;
  bool _isRepeat = false;

  // YouTube Music import state
  String? _importPlaylistId;
  String? _importUrl;
  bool _isImporting = false;

  // Progress text shown inside the import overlay (fetching / saving).
  String _importStatus = '';

  void _setImporting(bool value, [String status = '']) {
    _importStatus = status;
    if (mounted) {
      setState(() {
        _isImporting = value;
        if (!value) _importStatus = '';
      });
    } else {
      _isImporting = value;
      if (!value) _importStatus = '';
    }
  }

  Future<void> _openYouTubeImportDialog() async {
    if (_isImporting) return;
    _setImporting(true);
    try {
      final result = await YoutubeImportModeDialog.show(
        context,
        playlistTitle: 'Імпорт з YouTube',
        isOnlineDefault: true,
      );
      if (!mounted) return;
      if (result == null) return;
      _importUrl = result.url;
      _importPlaylistId = 'Імпорт з YouTube';
      final initialTarget = CustomPlaylist(name: 'Імпорт з YouTube', songs: []);
      final resolvedTarget = await _resolveImportedPlaylistTarget(
        source: initialTarget,
        url: result.url,
        playlistId: 'Імпорт з YouTube',
      );
      if (resolvedTarget == null) {
        _setImporting(false);
        return;
      }
      final target = resolvedTarget;
      if (result.isOnline) {
        await _saveYouTubeImportedTrackLink(target);
      } else {
        await _fetchAndSaveYouTubeImportedTracks(target);
      }
    } finally {
      _setImporting(false);
    }
  }

  Future<void> _showImportPlaylistDialog(CustomPlaylist playlist) async {
    if (_isImporting) return;
    _setImporting(true);

    // The URL field always opens empty — the user pastes (one-tap button)
    // or types the link themselves.
    final result = await YoutubeImportModeDialog.show(
      context,
      playlistTitle: playlist.name,
      isOnlineDefault: true,
    );

    if (!mounted) {
      _setImporting(false);
      return;
    }

    if (result == null) {
      _setImporting(false);
      return;
    }

    _importUrl = result.url;
    _importPlaylistId = playlist.name;

    try {
      if (result.isOnline) {
        // Online mode: record a playlist link reference in SQLite.
        await _saveYouTubeImportedTrackLink(playlist);
        return;
      }

      // Offline mode: import tracks locally and then save to SQLite library.
      await _fetchAndSaveYouTubeImportedTracks(playlist);
    } finally {
      _setImporting(false);
    }
  }

  Future<bool> _saveYouTubeImportedTrackLink(CustomPlaylist playlist) async {
    final url = _importUrl;
    final pid = _importPlaylistId;
    if (url == null) return false;
    _setImporting(true, 'Отримання треків з YouTube…');
    try {
      // Always resolve the true playlist metadata from the backend before
      // committing the local playlist object (title, tracks, playlist id).
      final target = await _resolveImportedPlaylistTarget(
        source: playlist,
        url: url,
        playlistId: pid,
      );
      if (target == null) return false;

      final tracks = await YoutubeImportService().fetchYouTubeTracks(
        pid ?? playlist.name,
        url,
      );
      final imported = YoutubeImportService.normalizeImportPayload(
        target.name,
        tracks,
        isOnline: true,
        playlistId: pid,
      );
      if (imported.isEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Неможливо отримати треки з YouTube')),
        );
        return false;
      }
      if (imported.isNotEmpty && mounted) {
        _setImporting(true, 'Збереження плейлиста…');
        setState(() {
          final idx = userPlaylists.indexWhere((p) => p.name == playlist.name);
          if (idx >= 0) {
            userPlaylists[idx].songs.addAll(imported.first.songs);
          } else {
            userPlaylists.addAll(imported);
          }
          // Online tracks must also appear in "All music": that screen renders
          // librarySongs only, so mirror the imported songs there (deduped by
          // trackId, never by the shared empty path).
          for (final s in imported.first.songs) {
            final duplicate = librarySongs.any((e) {
              if (e.trackId != null &&
                  s.trackId != null &&
                  e.trackId!.isNotEmpty &&
                  s.trackId!.isNotEmpty) {
                return e.trackId == s.trackId;
              }
              return e.title == s.title && e.artist == s.artist;
            });
            if (!duplicate) {
              librarySongs.add(s);
            }
          }
        });
        await _savePlaylists();
        await _saveLibrary();
      }
      return true;
    } catch (e) {
      debugPrint('Save online link failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Помилка онлайн-імпорту: $e')),
        );
      }
      return false;
    }
  }

  Future<CustomPlaylist?> _resolveImportedPlaylistTarget({
    required CustomPlaylist source,
    required String url,
    required String? playlistId,
  }) async {
    String resolvedTitle = source.name;
    try {
      final service = YoutubeImportService();
      final fetched = await service.fetchYouTubeTracks(
        playlistId ?? source.name,
        url,
      );
      final first = fetched.firstOrNull;
      if (first != null && first.playlistId != null && first.playlistId!.isNotEmpty) {
        // Backend returns the playlist title as playlist_id; use it as the
        // display name for the saved playlist object.
        resolvedTitle = first.playlistId!;
      }
    } catch (_) {
      // Keep the original dialog title if the backend endpoint is unavailable.
    }

    return CustomPlaylist(
      name: resolvedTitle.isNotEmpty ? resolvedTitle : 'Імпорт з YouTube',
      songs: [],
    );
  }

  Future<bool> _fetchAndSaveYouTubeImportedTracks(CustomPlaylist playlist) async {
    final pid = _importPlaylistId;
    final url = _importUrl;
    if (pid == null || url == null) return false;
    _setImporting(true, 'Отримання треків з YouTube…');
    try {
      // DEBUG: offline import branch diagnosis.
      // ignore: avoid_print
      print(
          '[ImportMode] OFFLINE selected — fetching tracks then downloading to local library (playlist="${playlist.name}")');
      final service = YoutubeImportService();
      final tracks = await service.fetchYouTubeTracks(pid, url);
      // Offline = playable local files: fetch resolves videoIds, then each
      // track is downloaded via /api/audio/stream into app documents.
      final downloaded = await _downloadImportedTracksToLibrary(tracks);
      if (downloaded.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Не вдалося завантажити жодного треку офлайн')),
          );
        }
        return false;
      }
      final offlinePlaylist = CustomPlaylist(
        name: playlist.name.isNotEmpty
            ? playlist.name
            : 'Imported YouTube Playlist',
        songs: downloaded,
      );
      if (mounted) {
        _setImporting(true, 'Збереження треків…');
        setState(() {
          final idx = userPlaylists.indexWhere((p) => p.name == playlist.name);
          if (idx >= 0) {
            userPlaylists[idx].songs.addAll(downloaded);
          } else {
            userPlaylists.add(offlinePlaylist);
          }
          // Offline tracks are also real local files → show them in library.
          for (final s in downloaded) {
            if (!librarySongs.any((e) =>
                e.path == s.path ||
                (e.trackId != null &&
                    s.trackId != null &&
                    e.trackId == s.trackId))) {
              librarySongs.add(s);
            }
          }
        });
        await _savePlaylists();
        await _saveLibrary();
      }
      return true;
    } catch (e) {
      debugPrint('Fetch YouTube tracks failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Помилка імпорту: $e')),
        );
      }
      return false;
    }
  }

  /// Downloads each imported [YouTubeImportedTrack] via
  /// `/api/audio/stream?id=<videoId>` into app documents and returns
  /// ready-to-play **offline** [Song]s (`isOnline: false`, real file path).
  Future<List<Song>> _downloadImportedTracksToLibrary(
    List<YouTubeImportedTrack> tracks,
  ) async {
    final dir = await getApplicationDocumentsDirectory();
    final out = <Song>[];
    var index = 0;
    for (final track in tracks) {
      index++;
      final videoId = track.videoId?.trim() ?? '';
      if (videoId.isEmpty) {
        // ignore: avoid_print
        print(
            '[ImportDownload] skip "${track.title}": null/empty videoId — stream URL cannot be built');
        continue;
      }
      final streamUrl = MusicService.getStreamUrl(videoId);
      // ignore: avoid_print
      print('[ImportDownload] ($index/${tracks.length}) stream: $streamUrl');
      try {
        final res = await http
            .get(Uri.parse(streamUrl))
            .timeout(const Duration(seconds: 60));
        if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
          // ignore: avoid_print
          print(
              '[ImportDownload] HTTP ${res.statusCode} for videoId=$videoId — skipped');
          continue;
        }
        final safeTitle = (track.title.isNotEmpty ? track.title : videoId)
            .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
        final filePath = '${dir.path}/${safeTitle}_$videoId.m4a';
        await File(filePath).writeAsBytes(res.bodyBytes);
        // ignore: avoid_print
        print('[ImportDownload] saved offline: $filePath');
        out.add(
          Song(
            title: track.title.isNotEmpty ? track.title : 'Unknown',
            artist: track.artist.isNotEmpty ? track.artist : 'Unknown',
            path: filePath,
            artworkUrl: track.thumbnailUrl,
            isOnline: false,
            trackId: videoId,
            durationSec: track.durationSec,
          ),
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Завантажено $index/${tracks.length}: ${track.title}'),
              duration: const Duration(milliseconds: 800),
            ),
          );
        }
      } catch (e) {
        // ignore: avoid_print
        print('[ImportDownload] failed videoId=$videoId: $e');
      }
    }
    return out;
  }

  final ValueNotifier<Song?> currentSongNotifier = ValueNotifier<Song?>(null);
  List<Song> currentQueue = [];
  int currentQueueIndex = -1;

  /// Whether a [PlayerScreen] route is currently on the navigation stack.
  /// Used to avoid pushing duplicate player screens when auto-navigation
  /// fires again (track change, next/prev, new search result tap).
  bool _playerScreenOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadLocalData();

    if (audioHandler is MyAudioHandler) {
      final handler = audioHandler as MyAudioHandler;
      handler.onNextPressed = _playNext;
      handler.onPrevPressed = _playPrev;
    }

    // Слухаємо нативну подію завершення треку від ExoPlayer
    DspEngine.instance.onTrackEnded = () {
      ListenTracker.instance.noteNaturalEnd();
      if (mounted) {
        _playNext();
      }
    };

    WidgetsBinding.instance.addPostFrameCallback((_) {
      EqualizerController.instance.loadSettings();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      ListenTracker.instance.flush();
    }
  }

  Future<void> _loadLocalData() async {
    final prefs = await SharedPreferences.getInstance();

    final libraryJson = prefs.getString('local_library_songs');
    if (libraryJson != null) {
      final List decoded = jsonDecode(libraryJson);
      librarySongs = decoded.map((item) => Song.fromJson(item)).toList();
    }

    final playlistsJson = prefs.getString('user_playlists');
    if (playlistsJson != null) {
      final List decoded = jsonDecode(playlistsJson);
      userPlaylists = decoded.map((item) => CustomPlaylist.fromJson(item)).toList();
    }

    if (mounted) {
      setState(() {
        isLoadingLibrary = false;
      });
    }
  }

  Future<void> _saveLibrary() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(librarySongs.map((s) => s.toJson()).toList());
    await prefs.setString('local_library_songs', encoded);
  }

  Future<void> _savePlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(userPlaylists.map((p) => p.toJson()).toList());
    await prefs.setString('user_playlists', encoded);
  }

  Future<Song> _parseLocalAudioFile(String filePath, String defaultName) async {
    String title = '';
    String artist = '';
    String? localCoverPath;

    try {
      final Tag? tag = await AudioTags.read(filePath);
      if (tag != null) {
        if (tag.trackArtist != null && tag.trackArtist!.trim().isNotEmpty) {
          artist = tag.trackArtist!.trim();
        }
        if (tag.title != null && tag.title!.trim().isNotEmpty) {
          title = tag.title!.trim();
        }

        if (tag.pictures.isNotEmpty) {
          final pictureBytes = tag.pictures.first.bytes;
          final dir = await getApplicationDocumentsDirectory();
          final coversDir = Directory('${dir.path}/covers');
          if (!await coversDir.exists()) {
            await coversDir.create(recursive: true);
          }

          final hash = filePath.hashCode.abs();
          final coverFile = File('${coversDir.path}/cover_$hash.jpg');
          await coverFile.writeAsBytes(pictureBytes);
          localCoverPath = coverFile.path;
        }
      }
    } catch (e) {
      debugPrint('Tag read error for $filePath: $e');
    }

    final rawName = defaultName.replaceAll(RegExp(r'\.[^\/$.?#]+$'), '').trim();

    if (title.isEmpty || artist.isEmpty) {
      if (rawName.contains(' - ')) {
        final parts = rawName.split(' - ');
        if (artist.isEmpty) artist = parts[0].trim();
        if (title.isEmpty) title = parts.sublist(1).join(' - ').trim();
      } else {
        if (title.isEmpty) title = rawName;
        if (artist.isEmpty) artist = AppLocale.tr('unknown_artist');
      }
    }

    return Song(
      title: title,
      path: filePath,
      artist: artist,
      artworkUrl: localCoverPath,
      isOnline: false,
    );
  }

  Future<void> _pickAudioFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: true,
      );
      if (result != null && result.files.isNotEmpty) {
        final List<Song> parsedSongs = [];

        for (var file in result.files) {
          if (file.path != null) {
            final song = await _parseLocalAudioFile(file.path!, file.name);
            parsedSongs.add(song);
          }
        }

        setState(() {
          librarySongs.addAll(parsedSongs);
        });
        await _saveLibrary();
      }
    } catch (e) {
      debugPrint('Pick file error: $e');
    }
  }

  void _showLibraryTrackMenu(Song song, int index) {
    final settings = SettingsController.instance;
    // Some screens pass a screen-local index (artist map / merged artist
    // views) that does NOT point into librarySongs — resolve the real
    // position by identity/content so "delete from storage" can never
    // remove the wrong entry. -1 = the song is not in the library at all
    // (e.g. an online track that only lives in a playlist).
    final libIndex = _libraryIndexOf(song);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        padding: const EdgeInsets.symmetric(vertical: 20.0, horizontal: 16.0),
        decoration: BoxDecoration(
          color: settings.surfaceColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.4),
              blurRadius: 20,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: settings.subTextColor.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      width: 46,
                      height: 46,
                      color: settings.backgroundColor,
                      child: () {
                        final art = song.artworkUrl;
                        if (art == null || art.isEmpty) {
                          return Icon(Icons.music_note, color: settings.accentColor);
                        }
                        if (art.startsWith('http')) {
                          return Image.network(art, fit: BoxFit.cover);
                        }
                        return Image.file(File(art), fit: BoxFit.cover);
                      }(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          song.title,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                            color: settings.textColor,
                            fontFamily: 'sans-serif-rounded',
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          song.artist,
                          style: TextStyle(
                            fontSize: 12,
                            color: settings.subTextColor,
                            fontFamily: 'sans-serif-rounded',
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Divider(height: 1, color: settings.textColor.withOpacity(0.08)),
              const SizedBox(height: 8),
              ListTile(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: settings.accentColor.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.playlist_add_rounded, color: settings.accentColor),
                ),
                title: Text(
                  AppLocale.tr('add_to_playlist'),
                  style: TextStyle(
                    color: settings.textColor,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'sans-serif-rounded',
                  ),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _showAddToPlaylistDialog(song);
                },
              ),
              // Hidden for songs that are not in the library at all (online
              // tracks that only live in a playlist / artist view) — the
              // action would be a no-op there.
              if (libIndex >= 0)
                ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
                  ),
                  title: Text(
                    AppLocale.tr('delete_from_storage'),
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'sans-serif-rounded',
                    ),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _deleteLibrarySong(libIndex);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _downloadSongToLibrary(Song song) async {
    if (!song.isOnline || song.trackId == null || song.trackId!.isEmpty) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Завантаження: ${song.title}...'),
        backgroundColor: Colors.orangeAccent.shade700,
        duration: const Duration(seconds: 2),
      ),
    );

    try {
      final streamUrl = MusicService.getStreamUrl(song.trackId!);
      final res = await http.get(Uri.parse(streamUrl));

      if (res.statusCode == 200) {
        final dir = await getApplicationDocumentsDirectory();
        final safeName = song.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
        final filePath = '${dir.path}/${safeName}_${song.trackId}.m4a';
        final file = File(filePath);
        await file.writeAsBytes(res.bodyBytes);

        final downloadedSong = Song(
          title: song.title,
          artist: song.artist,
          path: filePath,
          artworkUrl: song.artworkUrl,
          isOnline: false,
          trackId: song.trackId,
          // Keep the source track's length — dropping it here made every
          // downloaded track show 00:00 in the library/player.
          durationSec: song.durationSec,
        );

        setState(() {
          librarySongs.add(downloadedSong);
        });
        await _saveLibrary();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Трек збережено в медіатеку: ${song.title} :)'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        throw Exception('HTTP status ${res.statusCode}');
      }
    } catch (e) {
      debugPrint('Помилка завантаження: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Помилка завантаження: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  void _showTrackMenu(Song song) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      // Keep the sheet above the system navigation bar (back/home/recents)
      // so its actions are never covered by the OS gesture area.
      useSafeArea: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.only(
          top: 20.0,
          bottom: 20.0,
          left: 8.0,
          right: 8.0,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Text(
                song.title,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Divider(color: Colors.white12),
            if (song.isOnline)
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.greenAccent.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.download, color: Colors.greenAccent),
                ),
                title: const Text('Завантажити в медіатеку'),
                onTap: () {
                  Navigator.pop(ctx);
                  _downloadSongToLibrary(song);
                },
              ),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.orangeAccent.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.playlist_add, color: Colors.orangeAccent),
              ),
              title: Text(AppLocale.tr('add_to_playlist')),
              onTap: () {
                Navigator.pop(ctx);
                _showAddToPlaylistDialog(song);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showCreatePlaylistDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) {
        final accent = SettingsController.instance.accentColor;
        // Pick a readable foreground for the accent background (dark text on
        // light accents, light text on dark accents).
        final onAccent = accent.computeLuminance() > 0.5
            ? Colors.black
            : Colors.white;
        return AlertDialog(
        backgroundColor: const Color(0xFF222222),
        title: Text(AppLocale.tr('create_new_playlist')),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: AppLocale.tr('create_new_playlist'),
            hintStyle: const TextStyle(color: Colors.grey),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(AppLocale.tr('cancel'), style: const TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: onAccent,
            ),
            onPressed: () async {
              if (controller.text.trim().isNotEmpty) {
                setState(() {
                  userPlaylists.add(CustomPlaylist(name: controller.text.trim(), songs: []));
                });
                await _savePlaylists();
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: Text(AppLocale.tr('create'), style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      );
      },
    );
  }

  void _deleteLibrarySong(int index) async {
    setState(() {
      librarySongs.removeAt(index);
    });
    await _saveLibrary();
  }

  /// Resolves the position of [song] inside [librarySongs]. Identity first
  /// (screen-local lists hold the very same instances), then a stable
  /// content match (non-empty path, or trackId + origin). Returns -1 when
  /// the song is not in the library (e.g. an online track that only lives
  /// in a playlist or an artist view).
  int _libraryIndexOf(Song song) {
    for (var i = 0; i < librarySongs.length; i++) {
      if (identical(librarySongs[i], song)) return i;
    }
    for (var i = 0; i < librarySongs.length; i++) {
      final e = librarySongs[i];
      if (song.path.isNotEmpty && e.path == song.path) return i;
      if (song.trackId != null &&
          song.trackId!.isNotEmpty &&
          e.trackId == song.trackId &&
          e.isOnline == song.isOnline) {
        return i;
      }
    }
    return -1;
  }

  void _deletePlaylist(int index) async {
    setState(() {
      userPlaylists.removeAt(index);
    });
    await _savePlaylists();
  }

  void _showAddToPlaylistDialog(Song song) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF222222),
        title: Text(AppLocale.tr('add_to_playlist')),
        content: userPlaylists.isEmpty
            ? Text(AppLocale.tr('no_playlists'), style: const TextStyle(color: Colors.grey))
            : SizedBox(
                width: double.maxFinite,
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: userPlaylists.length,
                  itemBuilder: (c, idx) {
                    final pl = userPlaylists[idx];
                    return ListTile(
                      title: Text(pl.name, style: const TextStyle(color: Colors.white)),
                      trailing: const Icon(Icons.add, color: Colors.orangeAccent),
                      onTap: () {
                        Navigator.pop(ctx);
                        setState(() {
                          pl.songs.add(song);
                        });
                        _savePlaylists();
                        ListenTracker.instance.markAddedToPlaylist(song);
                      },
                    );
                  },
                ),
              ),
      ),
    );
  }

  /// Bulk delete: removes [songs] from the library and persists the change.
  Future<void> _deleteLibrarySongs(List<Song> songs) async {
    final toRemove = songs.toSet();
    setState(() {
      librarySongs.removeWhere((s) => toRemove.contains(s));
    });
    await _saveLibrary();
  }

  /// Bulk "add to playlist": shows the playlist picker for [songs] and
  /// persists the playlists afterwards.
  Future<void> _addSongsToPlaylists(List<Song> songs) async {
    if (songs.isEmpty || !mounted) return;
    await showBulkAddToPlaylistDialog(
      context,
      songs: songs,
      playlists: userPlaylists,
      onChanged: _savePlaylists,
    );
  }

  void _playSong(List<Song> songs, int index) async {
    if (index < 0 || index >= songs.length) return;
    final settings = SettingsController.instance;
    await ListenTracker.instance.flush();

    // Плавне згасання поточного аудіо перед завантаженням нового треку
    if (settings.isFadeEnabled && currentSongNotifier.value != null) {
      await DspEngine.instance.fadeVolume(
        from: DspEngine.instance.currentVolume,
        to: 0.0,
        durationMs: (settings.fadeOutMs / 2).round(),
      );
    }

    currentQueue = List.from(songs);
    currentQueueIndex = index;

    final song = songs[index];
    currentSongNotifier.value = song;

    // TEMP DEBUG: imported playlist playback diagnosis.
    // ignore: avoid_print
    print(
        '[PlayTap] title="${song.title}" artist="${song.artist}" isOnline=${song.isOnline} trackId=${song.trackId} path="${song.path}"');
    if (song.isOnline &&
        (song.trackId == null || song.trackId!.isEmpty)) {
      // ignore: avoid_print
      print(
          '[PlayTap] WARNING: online track has null/empty trackId — stream URL cannot be built!');
    }

    final customHandler = audioHandler as MyAudioHandler?;

    String finalUrl = song.path;
    if (song.isOnline) {
      if (song.trackId != null && song.trackId!.isNotEmpty) {
        finalUrl = MusicService.getStreamUrl(song.trackId!);
        // ignore: avoid_print
        print('[AudioSource] requesting stream URL: $finalUrl');
      } else if (!finalUrl.startsWith('http')) {
        debugPrint('--> [Player Error] Немає валідного URL або trackId!');
        return;
      }
    } else {
      if (!finalUrl.startsWith('file://') && !finalUrl.startsWith('content://')) {
        finalUrl = Uri.file(finalUrl).toString();
      }
    }

    try {
      debugPrint('--> [DSP ExoPlayer] Завантаження: $finalUrl');
      await DspEngine.instance.load(finalUrl);

      await Future.delayed(const Duration(milliseconds: 250));
      final totalMs = await DspEngine.instance.duration();

      // Prefer the live engine duration; if the engine can't report it yet,
      // fall back to the song's metadata duration. Never fake a fixed length.
      final trackDuration = totalMs > 0
          ? Duration(milliseconds: totalMs)
          : (song.durationSec != null && song.durationSec! > 0
              ? Duration(seconds: song.durationSec!)
              : Duration.zero);

      if (customHandler != null) {
        await customHandler.updateMetadata(
          song.title,
          song.artist,
          song.artworkUrl,
          duration: trackDuration,
        );
        await customHandler.play();
      } else {
        await DspEngine.instance.play();
      }

      // Плавна поява гучності нового треку
      if (settings.isFadeEnabled) {
        await DspEngine.instance.fadeVolume(
          from: 0.0,
          to: 1.0,
          durationMs: settings.fadeInMs,
        );
      } else {
        await DspEngine.instance.setVolume(1.0);
      }

      EqualizerController.instance.applyAll();
      await ListenTracker.instance.begin(song);

      // Auto-open the full player when a track starts from a list/search.
      // Guarded so we never stack duplicate PlayerScreen routes.
      _openPlayerScreen();
    } catch (e) {
      debugPrint('--> [Player Playback Error]: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Помилка відтворення: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  void _playNext() {
    if (currentQueue.isEmpty) return;

    if (_isRepeat && currentQueueIndex >= 0) {
      _playSong(currentQueue, currentQueueIndex);
      return;
    }

    if (_isShuffle && currentQueue.length > 1) {
      int nextIdx = math.Random().nextInt(currentQueue.length);
      while (nextIdx == currentQueueIndex && currentQueue.length > 1) {
        nextIdx = math.Random().nextInt(currentQueue.length);
      }
      _playSong(currentQueue, nextIdx);
      return;
    }

    if (currentQueueIndex + 1 < currentQueue.length) {
      _playSong(currentQueue, currentQueueIndex + 1);
    } else if (currentQueue.isNotEmpty) {
      _playSong(currentQueue, 0);
    }
  }

  void _playPrev() {
    if (currentQueue.isEmpty) return;

    if (currentQueueIndex - 1 >= 0) {
      _playSong(currentQueue, currentQueueIndex - 1);
    } else {
      _playSong(currentQueue, currentQueue.length - 1);
    }
  }

  void _handleToggleShuffle() {
    setState(() {
      _isShuffle = !_isShuffle;
    });

    final handler = audioHandler;
    if (handler != null) {
      handler.setShuffleMode(
        _isShuffle ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
      );
    }
  }

  void _handleToggleRepeat() {
    setState(() {
      _isRepeat = !_isRepeat;
    });

    final handler = audioHandler;
    if (handler != null) {
      handler.setRepeatMode(
        _isRepeat ? AudioServiceRepeatMode.one : AudioServiceRepeatMode.none,
      );
    }
  }

  Future<void> _handlePlayPauseToggle() async {
    if (audioHandler == null) return;
    final handler = audioHandler!;
    final settings = SettingsController.instance;
    final playing = handler.playbackState.value.playing;

    if (playing) {
      if (settings.isFadeEnabled) {
        await DspEngine.instance.smoothPause(settings.fadeOutMs);
      }
      await handler.pause();
    } else {
      await handler.play();
      if (settings.isFadeEnabled) {
        await DspEngine.instance.smoothPlay(settings.fadeInMs);
      } else {
        await DspEngine.instance.setVolume(1.0);
      }
    }
  }

  void _openPlayerScreen() {
    if (currentSongNotifier.value == null || audioHandler == null) return;
    // Never stack duplicate PlayerScreen routes: _playSong() calls this on
    // every track start, so without this guard next/prev/auto-play would push
    // a new player screen on top of the one already open.
    if (_playerScreenOpen) return;

    final handler = audioHandler!;
    _playerScreenOpen = true;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (ctx) => PlayerScreen(
          songNotifier: currentSongNotifier,
          audioHandler: handler,
          onPlayPause: _handlePlayPauseToggle,
          onNext: _playNext,
          onPrev: _playPrev,
          onDownloadCurrent: () {
            final cur = currentSongNotifier.value;
            if (cur != null) {
              _downloadSongToLibrary(cur);
            }
          },
          onToggleShuffle: _handleToggleShuffle,
          onToggleRepeat: _handleToggleRepeat,
          isShuffle: _isShuffle,
          isRepeat: _isRepeat,
          onToggleFavorite: () async {
            final cur = currentSongNotifier.value;
            if (cur == null) return false;
            return ListenTracker.instance.toggleFavorite(cur);
          },
          onPlayQueue: _playSong,
        ),
      ),
    ).whenComplete(() {
      _playerScreenOpen = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> pages = [
      MediaLibraryTab(
        librarySongs: librarySongs,
        userPlaylists: userPlaylists,
        currentPlayingSongNotifier: currentSongNotifier,
        isLoading: isLoadingLibrary,
        onPickFiles: _pickAudioFiles,
        onYouTubeImport: _openYouTubeImportDialog,
        onCreatePlaylist: _showCreatePlaylistDialog,
        onPlaySong: _playSong,
        onShowSongMenu: _showLibraryTrackMenu,
        onDeleteSongs: _deleteLibrarySongs,
        onAddSongsToPlaylist: _addSongsToPlaylists,
        onDeletePlaylist: _deletePlaylist,
        onOpenPlaylist: (playlist) {},
        onImportPlaylist: _showImportPlaylistDialog,
      ),
      DiscoverTab(
        onPlaySong: (songs, index) => _playSong(songs, index),
        onShowMenu: _showTrackMenu,
        currentSongNotifier: currentSongNotifier,
        onAddSongsToPlaylist: _addSongsToPlaylists,
      ),
      const EqualizerScreen(),
      const SettingsTab(),
    ];

    final settings = SettingsController.instance;

    return Stack(
      children: [
        Scaffold(
          body: Column(
            children: [
              Expanded(
                child: IndexedStack(
                  index: _currentIndex,
                  children: pages,
                ),
              ),
              MiniPlayer(
                currentSongNotifier: currentSongNotifier,
                onTap: _openPlayerScreen,
                onPrev: _playPrev,
                onNext: _playNext,
              ),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _currentIndex,
            onDestinationSelected: (index) => setState(() => _currentIndex = index),
            destinations: [
              NavigationDestination(
                icon: const Icon(Icons.library_music_rounded),
                label: AppLocale.tr('media'),
              ),
              NavigationDestination(
                icon: const Icon(Icons.language_rounded),
                label: AppLocale.tr('discover'),
              ),
              const NavigationDestination(
                icon: Icon(Icons.tune_rounded),
                label: 'EQ',
              ),
              NavigationDestination(
                icon: const Icon(Icons.settings_rounded),
                label: AppLocale.tr('settings'),
              ),
            ],
          ),
        ),
        // Import progress overlay: blocks interaction while tracks are
        // fetched over the network and persisted via _saveLibrary().
        if (_isImporting)
          Positioned.fill(
            child: AbsorbPointer(
              absorbing: true,
              child: Container(
                color: Colors.black.withOpacity(0.55),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 24,
                    ),
                    decoration: BoxDecoration(
                      color: settings.surfaceColor,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: settings.accentColor.withOpacity(0.25),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(
                          color: settings.accentColor,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _importStatus.isNotEmpty
                              ? _importStatus
                              : 'Імпорт плейлиста…',
                          style: TextStyle(
                            color: settings.textColor,
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                            decoration: TextDecoration.none,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
// -------------------------------------------------------------
// Вкладка "Інтернет"
// -------------------------------------------------------------
class DiscoverTab extends StatefulWidget {
  final Function(List<Song>, int) onPlaySong;
  final ValueChanged<Song> onShowMenu;
  final ValueNotifier<Song?> currentSongNotifier;

  /// Bulk "add selected search results to a playlist" (wired by the parent).
  final Future<void> Function(List<Song>)? onAddSongsToPlaylist;

  const DiscoverTab({
    super.key,
    required this.onPlaySong,
    required this.onShowMenu,
    required this.currentSongNotifier,
    this.onAddSongsToPlaylist,
  });

  @override
  State<DiscoverTab> createState() => _DiscoverTabState();
}

class _DiscoverTabState extends State<DiscoverTab> {
  static const int _pageSize = 25;

  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  List<Song> _popularTracks = [];
  List<Song> _recommendedTracks = [];
  List<Song> _searchResults = [];
  bool _isLoadingContent = true;
  bool _isSearching = false;
  bool _isLoadingMoreSearch = false;
  bool _searchHasMore = true;
  String _lastQuery = '';

  // Multi-select state for search results: long-press a row to enter.
  bool _selectionMode = false;
  final Set<Song> _selectedSongs = {};

  /// Autocomplete hints shown under the search box. Filled by a debounced
  /// request ([_onSearchChanged]) so we don't hit the backend on every
  /// keystroke.
  List<String> _suggestions = [];
  Timer? _suggestDebounce;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScrollNearBottom);
    _loadInitialMusic();
  }

  @override
  void dispose() {
    _suggestDebounce?.cancel();
    _scrollController
      ..removeListener(_onScrollNearBottom)
      ..dispose();
    _searchController.dispose();
    super.dispose();
  }

  /// Infinite scroll: when the outer list is ~400px from the bottom,
  /// append the next search batch (limit/offset paging).
  void _onScrollNearBottom() {
    if (!_scrollController.hasClients || _isLoadingMoreSearch) return;
    if (_searchResults.isEmpty || !_searchHasMore) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 400) {
      _loadMoreSearch();
    }
  }

  Future<void> _loadMoreSearch() async {
    if (_isLoadingMoreSearch || !_searchHasMore || _lastQuery.isEmpty) return;
    setState(() => _isLoadingMoreSearch = true);
    try {
      final page = await MusicService.search(
        _lastQuery,
        limit: _pageSize,
        offset: _searchResults.length,
      );
      if (!mounted) return;
      setState(() {
        final known = _searchResults
            .map((s) => s.trackId ?? '${s.artist}|${s.title}')
            .toSet();
        for (final song in page) {
          final key = song.trackId ?? '${song.artist}|${song.title}';
          if (known.add(key)) _searchResults.add(song);
        }
        if (page.length < _pageSize) _searchHasMore = false;
        _isLoadingMoreSearch = false;
      });
    } catch (e) {
      if (mounted) setState(() => _isLoadingMoreSearch = false);
    }
  }

  Future<void> _loadInitialMusic() async {
    if (mounted) setState(() => _isLoadingContent = true);
    try {
      final popular = await MusicService.getTrending();
      final recommended = await RecommendationEngine.instance.forYou();
      if (mounted) {
        setState(() {
          _popularTracks = popular;
          _recommendedTracks = recommended;
          _isLoadingContent = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingContent = false);
    }
  }

  /// Pull-to-refresh handler for the Internet feed: re-fetches trending +
  /// personalized tracks from the backend. If a search is active, refreshes
  /// the first search page instead (keeping infinite scroll offsets valid).
  Future<void> _refreshFeed() async {
    final activeQuery = _lastQuery.trim();
    if (_searchResults.isNotEmpty || activeQuery.isNotEmpty) {
      await _search(activeQuery);
      await _loadInitialMusic();
      return;
    }
    await _loadInitialMusic();
  }

  /// Debounced autocomplete: fires 350 ms after the user stops typing so a
  /// request is sent per pause, not per keystroke.
  void _onSearchChanged(String text) {
    _suggestDebounce?.cancel();
    final clean = text.trim();
    if (clean.length < 2) {
      if (_suggestions.isNotEmpty) setState(() => _suggestions = []);
      return;
    }
    _suggestDebounce = Timer(const Duration(milliseconds: 350), () {
      _fetchSuggestions(clean);
    });
  }

  Future<void> _fetchSuggestions(String q) async {
    final hints = await MusicService.suggest(q);
    if (!mounted) return;
    // Drop stale responses: the user kept typing while we were waiting.
    if (_searchController.text.trim() != q) return;
    if (hints.isEmpty && _suggestions.isEmpty) return;
    setState(() => _suggestions = hints);
  }

  /// Tap on a hint: fill the search box and run the search immediately.
  void _applySuggestion(String text) {
    _suggestDebounce?.cancel();
    _searchController.text = text;
    setState(() => _suggestions = []);
    _search(text);
  }

  Future<void> _search(String query) async {
    final clean = query.trim();
    if (clean.isEmpty) return;
    _suggestDebounce?.cancel();

    setState(() {
      _isSearching = true;
      _searchResults = [];
      _searchHasMore = true;
      _lastQuery = clean;
      _suggestions = [];
      // A new search invalidates the previous selection.
      _selectionMode = false;
      _selectedSongs.clear();
    });

    final res = await MusicService.search(clean, limit: _pageSize);
    if (mounted) {
      setState(() {
        _searchResults = res;
        _searchHasMore = res.length >= _pageSize;
        _isSearching = false;
      });
    }
  }

  // ---- Multi-select (search results only) ----

  void _enterSelection(Song song) {
    setState(() {
      _selectionMode = true;
      _selectedSongs.add(song);
    });
  }

  void _toggleSelection(Song song) {
    setState(() {
      if (!_selectedSongs.remove(song)) {
        _selectedSongs.add(song);
      }
      if (_selectedSongs.isEmpty) _selectionMode = false;
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectedSongs.clear();
    });
  }

  void _selectAllResults() {
    setState(() {
      _selectionMode = true;
      _selectedSongs
        ..clear()
        ..addAll(_searchResults);
    });
  }

  /// "Delete" for search results = drop them from the local results list.
  void _deleteSelectedResults() {
    setState(() {
      _searchResults.removeWhere((s) => _selectedSongs.contains(s));
      _selectedSongs.clear();
      _selectionMode = false;
    });
  }

  Future<void> _addSelectedToPlaylist() async {
    final toAdd = _selectedSongs.toList();
    final onAdd = widget.onAddSongsToPlaylist;
    _exitSelection();
    if (onAdd != null && toAdd.isNotEmpty) await onAdd(toAdd);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(AppLocale.tr('discover'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 24)),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: RefreshIndicator(
        color: SettingsController.instance.accentColor,
        onRefresh: _refreshFeed,
        child: ListView(
        controller: _scrollController,
        // AlwaysScrollable keeps pull-to-refresh working even when the
        // feed is short and would otherwise not overscroll.
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        children: [
          Container(
            decoration: BoxDecoration(
              color: SettingsController.instance.surfaceColor,
              borderRadius: BorderRadius.circular(16),
            ),
            child: TextField(
              controller: _searchController,
              style: TextStyle(color: SettingsController.instance.textColor),
              onSubmitted: _search,
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                hintText: AppLocale.tr('search_web_hint'),
                hintStyle: TextStyle(color: SettingsController.instance.subTextColor),
                prefixIcon: Icon(Icons.search, color: SettingsController.instance.accentColor),
                suffixIcon: _isSearching
                    // Small inline "searching" indicator lives in the search
                    // field itself, so we don't need a separate full-page
                    // spinner that duplicates this state.
                    ? Padding(
                        padding: const EdgeInsets.all(14.0),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: SettingsController.instance.accentColor,
                          ),
                        ),
                      )
                    : IconButton(
                        icon: Icon(Icons.send, color: SettingsController.instance.accentColor),
                        onPressed: () => _search(_searchController.text),
                      ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),

          // Autocomplete dropdown: debounced suggestions under the search box.
          if (_suggestions.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 6),
              decoration: BoxDecoration(
                color: SettingsController.instance.surfaceColor,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: SettingsController.instance.accentColor
                      .withOpacity(0.2),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final hint in _suggestions)
                    InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _applySuggestion(hint),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 11,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.search,
                              size: 16,
                              color: SettingsController.instance.subTextColor,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                hint,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color:
                                      SettingsController.instance.textColor,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            Icon(
                              Icons.north_west,
                              size: 14,
                              color: SettingsController.instance.subTextColor,
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),

          const SizedBox(height: 20),

          // Note: the "searching" indicator is the small spinner inside the
          // search field (see suffixIcon). We intentionally do NOT render a
          // second full-page spinner here — it duplicated that state and made
          // the whole feed jump. While searching we simply keep showing the
          // previous content until fresh results arrive.
          if (_searchResults.isNotEmpty) ...[
            if (_selectionMode) ...[
              buildMultiSelectBar(
                count: _selectedSongs.length,
                onSelectAll: _selectAllResults,
                onAddToPlaylist: _addSelectedToPlaylist,
                onDelete: _deleteSelectedResults,
                onClose: _exitSelection,
              ),
              const SizedBox(height: 8),
            ],
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Результати пошуку', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.grey),
                  onPressed: () => setState(() => _searchResults = []),
                )
              ],
            ),
            const SizedBox(height: 8),
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount:
                  _searchResults.length + (_isLoadingMoreSearch ? 1 : 0),
              itemBuilder: (context, index) {
                if (index >= _searchResults.length) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16.0),
                    child: Center(
                      child: CircularProgressIndicator(
                          color: SettingsController.instance.accentColor),
                    ),
                  );
                }
                final song = _searchResults[index];
                final selecting = _selectionMode;
                return _buildTrackTile(
                  song,
                  _searchResults,
                  index,
                  selected: _selectedSongs.contains(song),
                  onLongPress: selecting ? null : () => _enterSelection(song),
                  onToggleSelect:
                      selecting ? () => _toggleSelection(song) : null,
                );
              },
            ),
          ] else ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(AppLocale.tr('popular_in_ukraine'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                Text('${_popularTracks.length} ${AppLocale.tr('tracks_count')}', style: const TextStyle(color: Colors.white38, fontSize: 13)),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 180,
              child: _isLoadingContent
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _popularTracks.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 12),
                      itemBuilder: (context, index) {
                        final song = _popularTracks[index];
                        return GestureDetector(
                          onTap: () => widget.onPlaySong(_popularTracks, index),
                          child: SizedBox(
                            width: 130,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(16),
                                  child: Container(
                                    width: 130,
                                    height: 120,
                                    color: const Color(0xFF222222),
                                    child: song.artworkUrl != null
                                        ? Image.network(song.artworkUrl!, fit: BoxFit.cover)
                                        : const Icon(Icons.music_note, color: Colors.orangeAccent),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  song.title,
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  song.artist,
                                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 24),
            Text(
              AppLocale.tr('you_might_like'),
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: SettingsController.instance.textColor,
              ),
            ),
            const SizedBox(height: 12),
            _isLoadingContent
                ? Center(
                    child: CircularProgressIndicator(
                      color: SettingsController.instance.accentColor,
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _recommendedTracks.length,
                    itemBuilder: (context, index) {
                      final song = _recommendedTracks[index];
                      return _buildTrackTile(song, _recommendedTracks, index);
                    },
                  ),
          ],
        ],
        ),
      ),
    );
  }

  Widget _buildTrackTile(
    Song song,
    List<Song> queue,
    int index, {
    bool selected = false,
    VoidCallback? onLongPress,
    VoidCallback? onToggleSelect,
  }) {
    final settings = SettingsController.instance;
    final accent = settings.accentColor;
    final selecting = onToggleSelect != null;

    return GestureDetector(
      onLongPress: onLongPress,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: selecting && selected
              ? accent.withOpacity(0.16)
              : settings.surfaceColor,
          borderRadius: BorderRadius.circular(16),
          border: selecting && selected
              ? Border.all(color: accent.withOpacity(0.6), width: 1)
              : null,
        ),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: 48,
              height: 48,
              color: settings.bgTheme == BgTheme.white
                  ? settings.accentColor.withOpacity(0.12)
                  : const Color(0xFF242424),
              child: song.artworkUrl != null && song.artworkUrl!.isNotEmpty
                  ? Image.network(
                      song.artworkUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Icon(
                        Icons.music_note,
                        color: settings.accentColor,
                      ),
                    )
                  : Icon(Icons.music_note, color: settings.accentColor),
            ),
          ),
          title: Text(
            song.title,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
              color: settings.textColor,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => showArtistProfileSheet(
              context,
              song.artist,
              onPlaySong: widget.onPlaySong,
            ),
            child: Text(
              song.artist,
              style: TextStyle(
                color: settings.subTextColor,
                fontSize: 12,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          trailing: selecting
              ? Checkbox(
                  value: selected,
                  activeColor: accent,
                  onChanged: (_) => onToggleSelect(),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _TrackPlayButton(
                      song: song,
                      currentSongNotifier: widget.currentSongNotifier,
                      onPlay: () => widget.onPlaySong(queue, index),
                    ),
                    IconButton(
                      icon: Icon(Icons.more_vert, color: settings.subTextColor),
                      onPressed: () => widget.onShowMenu(song),
                    ),
                  ],
                ),
          onTap: selecting ? onToggleSelect : () => widget.onPlaySong(queue, index),
        ),
      ),
    );
  }
}

// -------------------------------------------------------------
// Кнопка Play/Pause у списках треків: синхронізована з реальним
// станом аудіоадаптера для поточного треку, з плавною анімацією
// перемикання (як на головному екрані плеєра).
// -------------------------------------------------------------
class _TrackPlayButton extends StatelessWidget {
  final Song song;
  final ValueNotifier<Song?> currentSongNotifier;
  final VoidCallback onPlay;

  const _TrackPlayButton({
    required this.song,
    required this.currentSongNotifier,
    required this.onPlay,
  });

  /// Track identity: online tracks match by trackId (videoId), local ones by
  /// path. Falls back to path when either side has no trackId.
  bool _isCurrent(Song? current) {
    if (current == null) return false;
    if (current.trackId != null && song.trackId != null) {
      return current.trackId == song.trackId;
    }
    return current.path == song.path;
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsController.instance;

    return ValueListenableBuilder<Song?>(
      valueListenable: currentSongNotifier,
      builder: (context, current, _) {
        final isCurrent = _isCurrent(current);

        // Not the current track: plain play triangle, starts it.
        if (!isCurrent) {
          return Container(
            decoration: BoxDecoration(
              color: settings.accentColor,
              shape: BoxShape.circle,
            ),
            child: IconButton(
              iconSize: 22,
              icon: const Icon(Icons.play_arrow_rounded, color: Colors.black),
              onPressed: onPlay,
            ),
          );
        }

        // Current track: mirror the real playback state of the audio handler.
        return StreamBuilder<PlaybackState>(
          stream: audioHandler?.playbackState ?? const Stream.empty(),
          builder: (context, snapshot) {
            final isPlaying = snapshot.data?.playing ?? false;

            return Container(
              decoration: BoxDecoration(
                color: settings.accentColor,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                iconSize: 22,
                onPressed: () async {
                  final handler = audioHandler;
                  if (handler == null) return;
                  if (isPlaying) {
                    await handler.pause();
                  } else {
                    await handler.play();
                  }
                },
                // Same animated switch as the big button in PlayerScreen.
                icon: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 280),
                  switchInCurve: Curves.easeOutBack,
                  switchOutCurve: Curves.easeInBack,
                  transitionBuilder: (child, animation) {
                    return ScaleTransition(
                      scale: animation,
                      child: FadeTransition(opacity: animation, child: child),
                    );
                  },
                  child: Icon(
                    isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    key: ValueKey<bool>(isPlaying),
                    size: 22,
                    color: Colors.black,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ----------------------------------------------------
// Нижній міні-плеєр
// ----------------------------------------------------
class MiniPlayer extends StatefulWidget {
  final ValueNotifier<Song?> currentSongNotifier;
  final VoidCallback onTap;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  const MiniPlayer({
    super.key,
    required this.currentSongNotifier,
    required this.onTap,
    required this.onPrev,
    required this.onNext,
  });

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> {
  Timer? _progressTimer;

  @override
  void initState() {
    super.initState();
    // Stage 4: light ticker for the progress bar. PlaybackState.position
    // extrapolates realtime from updateTime while playing, so polling at
    // 400ms keeps the bar in sync smoothly between handler updates.
    _progressTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (mounted && widget.currentSongNotifier.value != null) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    super.dispose();
  }

  /// Playback progress in 0..1, or null when the duration is unknown.
  double? _progress(Song song) {
    final state = audioHandler?.playbackState.value;
    if (state == null) return null;

    Duration duration = audioHandler?.mediaItem.value?.duration ?? Duration.zero;
    if (duration.inMilliseconds <= 0 && (song.durationSec ?? 0) > 0) {
      duration = Duration(seconds: song.durationSec!);
    }
    if (duration.inMilliseconds <= 0) return null;

    return (state.position.inMilliseconds / duration.inMilliseconds)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsController.instance;

    return ValueListenableBuilder<Song?>(
      valueListenable: widget.currentSongNotifier,
      builder: (context, song, _) {
        if (song == null) return const SizedBox.shrink();
        final progress = _progress(song);

        return GestureDetector(
          onTap: widget.onTap,
          child: Container(
            height: 64,
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: settings.bgTheme == BgTheme.white
                  ? settings.accentColor.withOpacity(0.18)
                  : settings.surfaceColor,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: settings.accentColor.withOpacity(0.2),
                width: 1,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Column(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              width: 44,
                              height: 44,
                              color: settings.bgTheme == BgTheme.white
                                  ? settings.accentColor.withOpacity(0.12)
                                  : const Color(0xFF2C2C2C),
                              child: () {
                                final art = song.artworkUrl;
                                if (art == null || art.isEmpty) {
                                  return Icon(Icons.music_note, color: settings.accentColor);
                                }
                                if (art.startsWith('http')) {
                                  return Image.network(
                                    art,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => Icon(
                                      Icons.music_note,
                                      color: settings.accentColor,
                                    ),
                                  );
                                }
                                return Image.file(
                                  File(art),
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => Icon(
                                    Icons.music_note,
                                    color: settings.accentColor,
                                  ),
                                );
                              }(),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  song.title,
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                    color: settings.textColor,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  song.artist,
                                  style: TextStyle(
                                    color: settings.subTextColor,
                                    fontSize: 11,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: Icon(Icons.skip_previous, color: settings.textColor, size: 22),
                            onPressed: widget.onPrev,
                          ),
                          StreamBuilder<PlaybackState>(
                            stream: audioHandler?.playbackState ?? const Stream.empty(),
                            builder: (context, stateSnapshot) {
                              final playing = stateSnapshot.data?.playing ?? false;
                              return Container(
                                decoration: BoxDecoration(
                                  color: settings.accentColor,
                                  shape: BoxShape.circle,
                                ),
                                child: IconButton(
                                  iconSize: 22,
                                  icon: Icon(
                                    playing ? Icons.pause : Icons.play_arrow,
                                    color: Colors.black,
                                  ),
                                  onPressed: () async {
                                    if (audioHandler == null) return;
                                    if (playing) {
                                      await audioHandler!.pause();
                                    } else {
                                      await audioHandler!.play();
                                    }
                                  },
                                ),
                              );
                            },
                          ),
                          IconButton(
                            icon: Icon(Icons.skip_next, color: settings.textColor, size: 22),
                            onPressed: widget.onNext,
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (progress != null)
                    SizedBox(
                      height: 3,
                      width: double.infinity,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // Faint full-width track under the fill.
                          Container(color: settings.accentColor.withOpacity(0.15)),
                          // Animated fill — the tween smooths the 400ms ticks.
                          TweenAnimationBuilder<double>(
                            tween: Tween(begin: 0.0, end: progress),
                            duration: const Duration(milliseconds: 380),
                            curve: Curves.linear,
                            builder: (context, value, _) => LayoutBuilder(
                              builder: (context, constraints) => Align(
                                alignment: Alignment.centerLeft,
                                child: SizedBox(
                                  width: constraints.maxWidth * value,
                                  height: 3,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: [
                                          settings.accentColor,
                                          settings.accentColor.withOpacity(0.75),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// -------------------------------------------------------------
// Вкладка "Налаштування"
// -------------------------------------------------------------
/// Donation link opened by the "Підтримати проєкт" button in Settings
/// (Monobank jar).
const String kDonateUrl = 'https://send.monobank.ua/jar/6E2iZgBgRP';

class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key});

  /// Accent-colored section header used to separate settings categories.
  static Widget _sectionTitle(SettingsController settings, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        title,
        style: TextStyle(
          color: settings.accentColor,
          fontWeight: FontWeight.bold,
          fontSize: 14,
        ),
      ),
    );
  }

  /// Sends a user-written bug report to the backend, which forwards it to
  /// Telegram. Shows a localized SnackBar with the result.
  static Future<void> _sendBugReport(
      BuildContext context, SettingsController settings, String message) async {
    final text = message.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(settings.tr('report_bug_empty')),
          backgroundColor: Colors.orangeAccent,
        ),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(settings.tr('report_bug_sending'))),
    );
    try {
      final res = await http
          .post(
            Uri.parse('${MusicService.baseUrl}/api/report-bug'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'message': text, 'app_version': '1.1'}),
          )
          .timeout(const Duration(seconds: 20));
      if (!context.mounted) return;
      if (res.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(settings.tr('report_bug_success')),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(settings.tr('report_bug_error')),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(settings.tr('report_bug_error')),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  /// Dialog with a text field where the user describes the problem.
  static void _showBugReportDialog(
      BuildContext context, SettingsController settings) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: settings.surfaceColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.orangeAccent.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.bug_report_rounded,
                  color: Colors.orangeAccent,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  settings.tr('report_bug'),
                  style: TextStyle(
                    color: settings.textColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 17,
                  ),
                ),
              ),
            ],
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 5,
            minLines: 3,
            style: TextStyle(color: settings.textColor),
            decoration: InputDecoration(
              hintText: settings.tr('report_bug_hint'),
              hintStyle: TextStyle(color: settings.subTextColor),
              filled: true,
              fillColor: settings.backgroundColor,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(
                settings.tr('cancel'),
                style: const TextStyle(color: Colors.grey),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: settings.accentColor,
                foregroundColor: settings.accentColor.computeLuminance() > 0.5
                    ? Colors.black
                    : Colors.white,
              ),
              onPressed: () async {
                if (controller.text.trim().isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(settings.tr('report_bug_empty')),
                      backgroundColor: Colors.orangeAccent,
                    ),
                  );
                  return;
                }
                Navigator.pop(ctx);
                await _sendBugReport(context, settings, controller.text);
                controller.dispose();
              },
              child: Text(
                settings.tr('send'),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Rounded surface container that groups the rows of a single category.
  static Widget _sectionCard(SettingsController settings, {required Widget child}) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: settings.surfaceColor,
        borderRadius: BorderRadius.circular(16),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsController.instance;

    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) {
        String currentLangLabel = 'Українська 🇺🇦';
        if (settings.currentLang == 'en') currentLangLabel = 'English 🇬🇧';
        if (settings.currentLang == 'pl') currentLangLabel = 'Polski 🇵🇱';
        if (settings.currentLang == 'de') currentLangLabel = 'Deutsch 🇩🇪';
        if (settings.currentLang == 'es') currentLangLabel = 'Español 🇪🇸';

        String currentThemeLabel = settings.tr('black_amoled');
        if (settings.bgTheme == BgTheme.dark) currentThemeLabel = settings.tr('dark');
        if (settings.bgTheme == BgTheme.white) currentThemeLabel = settings.tr('white');

        return Scaffold(
          backgroundColor: settings.backgroundColor,
          appBar: AppBar(
            title: Text(
              settings.tr('settings'),
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 24, color: settings.textColor),
            ),
            backgroundColor: settings.backgroundColor,
            elevation: 0,
          ),
          body: ListView(
            padding: const EdgeInsets.all(16.0),
            children: [
              // --- Категорія: Загальні ---
              _sectionTitle(settings, settings.tr('category_general')),
              _sectionCard(
                settings,
                child: Column(
                  children: [
                    ListTile(
                      leading: Icon(Icons.language, color: settings.accentColor),
                      title: Text(
                        settings.tr('language'),
                        style: TextStyle(fontWeight: FontWeight.w500, color: settings.textColor),
                      ),
                      subtitle: Text(currentLangLabel, style: TextStyle(color: settings.subTextColor)),
                      trailing: Icon(Icons.chevron_right, color: settings.subTextColor),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const LanguageScreen()),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // --- Категорія: Вигляд ---
              _sectionTitle(settings, settings.tr('category_appearance')),
              _sectionCard(
                settings,
                child: Column(
                  children: [
                    ListTile(
                      leading: Icon(Icons.palette, color: settings.accentColor),
                      title: Text(
                        settings.tr('theme'),
                        style: TextStyle(fontWeight: FontWeight.w500, color: settings.textColor),
                      ),
                      subtitle: Text(currentThemeLabel, style: TextStyle(color: settings.subTextColor)),
                      trailing: Icon(Icons.chevron_right, color: settings.subTextColor),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const ThemeSettingsScreen()),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // --- Категорія: Відтворення ---
              _sectionTitle(settings, settings.tr('category_playback')),
              _sectionCard(
                settings,
                child: Column(
                  children: [
                    ListTile(
                      leading: Icon(Icons.graphic_eq_rounded, color: settings.accentColor),
                      title: Text(
                        settings.tr('playback_settings'),
                        style: TextStyle(fontWeight: FontWeight.w500, color: settings.textColor),
                      ),
                      subtitle: Text(
                        settings.isFadeEnabled
                            ? '${(settings.fadeInMs / 1000).toStringAsFixed(1)}s / ${(settings.fadeOutMs / 1000).toStringAsFixed(1)}s'
                            : settings.tr('disabled'),
                        style: TextStyle(color: settings.subTextColor),
                      ),
                      trailing: Icon(Icons.chevron_right, color: settings.subTextColor),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const PlaybackSettingsScreen()),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // --- Категорія: Еквалайзер та пресети ---
              _sectionTitle(settings, settings.tr('category_equalizer')),
              _sectionCard(
                settings,
                child: Column(
                  children: [
                    ListTile(
                      leading: Icon(Icons.file_upload_rounded, color: settings.accentColor),
                      title: Text(
                        settings.tr('import_preset'),
                        style: TextStyle(fontWeight: FontWeight.w500, color: settings.textColor),
                      ),
                      subtitle: Text(
                        settings.tr('import_preset_desc'),
                        style: TextStyle(color: settings.subTextColor),
                      ),
                      trailing: Icon(Icons.chevron_right, color: settings.subTextColor),
                      onTap: () async {
                        final importedName = await EqualizerController.instance.importPresetFromFile();
                        if (context.mounted) {
                          if (importedName != null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  settings.tr('import_success').replaceAll('{name}', importedName),
                                ),
                                backgroundColor: Colors.green,
                              ),
                            );
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(settings.tr('import_error')),
                                backgroundColor: Colors.redAccent,
                              ),
                            );
                          }
                        }
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // --- Категорія: Про додаток ---
              _sectionTitle(settings, settings.tr('about')),
              _sectionCard(
                settings,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: settings.accentColor.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(Icons.music_note_rounded, color: settings.accentColor),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'OpenTube 1.1',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                    color: settings.textColor,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  settings.tr('app_tagline'),
                                  style: TextStyle(color: settings.subTextColor, fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Divider(height: 1, color: settings.textColor.withOpacity(0.08)),
                      const SizedBox(height: 16),
                      Text(
                        settings.tr('changelog'),
                        style: TextStyle(
                          color: settings.accentColor,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: settings.accentColor.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: settings.accentColor.withOpacity(0.25)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.new_releases_rounded, color: settings.accentColor, size: 18),
                                const SizedBox(width: 8),
                                Text(
                                  settings.tr('release'),
                                  style: TextStyle(
                                    color: settings.accentColor,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              settings.tr('release_notes'),
                              style: TextStyle(color: settings.subTextColor, height: 1.5, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // --- Баг-репорт у Telegram (перед донатом, в самому низу) ---
              _sectionCard(
                settings,
                child: ListTile(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.orangeAccent.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.bug_report_rounded,
                        color: Colors.orangeAccent),
                  ),
                  title: Text(
                    settings.tr('report_bug'),
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                      color: settings.textColor,
                      fontFamily: 'sans-serif-rounded',
                    ),
                  ),
                  subtitle: Text(
                    settings.tr('report_bug_desc'),
                    style:
                        TextStyle(color: settings.subTextColor, fontSize: 12),
                  ),
                  trailing: Icon(Icons.chevron_right_rounded,
                      color: settings.subTextColor, size: 20),
                  onTap: () => _showBugReportDialog(context, settings),
                ),
              ),
              const SizedBox(height: 12),
              // --- Кнопка донату (в самому низу, одразу після версії) ---
              _sectionCard(
                settings,
                child: ListTile(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child:
                        const Icon(Icons.coffee_rounded, color: Colors.redAccent),
                  ),
                  title: Text(
                    settings.tr('support_project'),
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                      color: settings.textColor,
                      fontFamily: 'sans-serif-rounded',
                    ),
                  ),
                  subtitle: Text(
                    settings.tr('support_project_desc'),
                    style:
                        TextStyle(color: settings.subTextColor, fontSize: 12),
                  ),
                  trailing: Icon(Icons.open_in_new_rounded,
                      color: settings.subTextColor, size: 18),
                  onTap: () => launchUrl(
                    Uri.parse(kDonateUrl),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// -------------------------------------------------------------
// Вкладка "Моя медіатека" (Стилізований Хаб)
// -------------------------------------------------------------
class MediaLibraryTab extends StatefulWidget {
  final List<Song> librarySongs;
  final List<CustomPlaylist> userPlaylists;
  final ValueNotifier<Song?> currentPlayingSongNotifier;
  final bool isLoading;
  final VoidCallback onPickFiles;
  final VoidCallback? onYouTubeImport;
  final VoidCallback onCreatePlaylist;
  final Function(List<Song>, int) onPlaySong;
  final Function(Song, int) onShowSongMenu;
  final Future<void> Function(List<Song>) onDeleteSongs;
  final Future<void> Function(List<Song>) onAddSongsToPlaylist;
  final ValueChanged<int> onDeletePlaylist;
  final Function(CustomPlaylist) onOpenPlaylist;
  final Function(CustomPlaylist)? onImportPlaylist;

  const MediaLibraryTab({
    super.key,
    required this.librarySongs,
    required this.userPlaylists,
    required this.currentPlayingSongNotifier,
    required this.isLoading,
    required this.onPickFiles,
    this.onYouTubeImport,
    required this.onCreatePlaylist,
    required this.onPlaySong,
    required this.onShowSongMenu,
    required this.onDeleteSongs,
    required this.onAddSongsToPlaylist,
    required this.onDeletePlaylist,
    required this.onOpenPlaylist,
    this.onImportPlaylist,
  });

  @override
  State<MediaLibraryTab> createState() => _MediaLibraryTabState();
}

class _MediaLibraryTabState extends State<MediaLibraryTab> {
  final GlobalKey<NavigatorState> _nestedNavKey = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_nestedNavKey.currentState?.canPop() ?? false) {
          _nestedNavKey.currentState?.pop();
        }
      },
      child: Navigator(
        key: _nestedNavKey,
        onGenerateRoute: (settings) {
          return MaterialPageRoute(
            builder: (nestedContext) => _MediaHubHomeView(
              librarySongs: widget.librarySongs,
              userPlaylists: widget.userPlaylists,
              currentPlayingSongNotifier: widget.currentPlayingSongNotifier,
              isLoading: widget.isLoading,
              onPickFiles: widget.onPickFiles,
              onYouTubeImport: widget.onYouTubeImport,
              onCreatePlaylist: widget.onCreatePlaylist,
              onPlaySong: widget.onPlaySong,
              onShowSongMenu: widget.onShowSongMenu,
              onDeleteSongs: widget.onDeleteSongs,
              onAddSongsToPlaylist: widget.onAddSongsToPlaylist,
              onDeletePlaylist: widget.onDeletePlaylist,
              onOpenPlaylist: widget.onOpenPlaylist,
              onImportPlaylist: widget.onImportPlaylist,
            ),
          );
        },
      ),
    );
  }
}

class _MediaHubHomeView extends StatelessWidget {
  final List<Song> librarySongs;
  final List<CustomPlaylist> userPlaylists;
  final ValueNotifier<Song?> currentPlayingSongNotifier;
  final bool isLoading;
  final VoidCallback onPickFiles;
  final VoidCallback? onYouTubeImport;
  final VoidCallback onCreatePlaylist;
  final Function(List<Song>, int) onPlaySong;
  final Function(Song, int) onShowSongMenu;
  final Future<void> Function(List<Song>) onDeleteSongs;
  final Future<void> Function(List<Song>) onAddSongsToPlaylist;
  final ValueChanged<int> onDeletePlaylist;
  final Function(CustomPlaylist) onOpenPlaylist;
  final Function(CustomPlaylist)? onImportPlaylist;

  const _MediaHubHomeView({
    required this.librarySongs,
    required this.userPlaylists,
    required this.currentPlayingSongNotifier,
    required this.isLoading,
    required this.onPickFiles,
    this.onYouTubeImport,
    required this.onCreatePlaylist,
    required this.onPlaySong,
    required this.onShowSongMenu,
    required this.onDeleteSongs,
    required this.onAddSongsToPlaylist,
    required this.onDeletePlaylist,
    required this.onOpenPlaylist,
    this.onImportPlaylist,
  });

  Widget _buildHubCard({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    required SettingsController settings,
    required VoidCallback onTap,
  }) {
    final accent = settings.accentColor;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: settings.surfaceColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: accent.withOpacity(0.08),
          width: 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        accent.withOpacity(0.25),
                        accent.withOpacity(0.08),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: accent.withOpacity(0.2), width: 1),
                  ),
                  child: Icon(icon, color: accent, size: 28),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                          color: settings.textColor,
                          fontFamily: 'sans-serif-rounded',
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: settings.subTextColor,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          fontFamily: 'sans-serif-rounded',
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.arrow_forward_ios_rounded,
                  color: settings.subTextColor.withOpacity(0.5),
                  size: 16,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsController.instance;

    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) {
        final Map<String, List<Song>> artistMap = {};

        bool isSameSong(Song a, Song b) {
          if (a.trackId != null &&
              a.trackId!.isNotEmpty &&
              b.trackId != null &&
              b.trackId!.isNotEmpty) {
            return a.trackId == b.trackId;
          }
          if (a.path.isNotEmpty && b.path.isNotEmpty) return a.path == b.path;
          return a.title == b.title && a.artist == b.artist;
        }

        void addToArtistMap(Song s) {
          final name = s.artist.trim().isEmpty
              ? AppLocale.tr('unknown_artist')
              : s.artist.trim();
          final bucket = artistMap.putIfAbsent(name, () => []);
          if (bucket.any((e) => isSameSong(e, s))) return;
          bucket.add(s);
        }

        // Library first, then user playlists: tracks that were only added to
        // a playlist (never mirrored into "All music") must still appear
        // under Artists — otherwise the tab stays empty for playlist-only
        // users.
        for (var s in librarySongs) {
          addToArtistMap(s);
        }
        for (var pl in userPlaylists) {
          for (var s in pl.songs) {
            addToArtistMap(s);
          }
        }

        return Scaffold(
          backgroundColor: settings.backgroundColor,
          appBar: AppBar(
            title: Text(
              AppLocale.tr('my_library'),
              style: TextStyle(
                color: settings.textColor,
                fontWeight: FontWeight.w900,
                fontSize: 26,
                fontFamily: 'sans-serif-rounded',
              ),
            ),
            backgroundColor: settings.backgroundColor,
            elevation: 0,
            actions: [
              if (onYouTubeImport != null)
                IconButton(
                  icon: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: settings.accentColor.withOpacity(0.15),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.link_rounded,
                      color: settings.accentColor,
                      size: 22,
                    ),
                  ),
                  tooltip: 'Імпорт з YouTube',
                  onPressed: onYouTubeImport,
                ),
              IconButton(
                icon: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: settings.accentColor.withOpacity(0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.add_rounded, color: settings.accentColor, size: 22),
                ),
                tooltip: AppLocale.tr('add_local_tracks'),
                onPressed: onPickFiles,
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: isLoading
              ? Center(child: CircularProgressIndicator(color: settings.accentColor))
              : ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                  children: [
                    _buildHubCard(
                      context: context,
                      icon: Icons.music_note_rounded,
                      title: AppLocale.tr('all_music'),
                      subtitle: '${librarySongs.length} ${AppLocale.tr('tracks_count')} ${AppLocale.tr('in_storage')}',
                      settings: settings,
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => AllSongsScreen(
                              librarySongs: librarySongs,
                              currentPlayingSongNotifier: currentPlayingSongNotifier,
                              onPlaySong: onPlaySong,
                              onShowSongMenu: onShowSongMenu,
                              onDeleteSongs: onDeleteSongs,
                              onAddSongsToPlaylist: onAddSongsToPlaylist,
                            ),
                          ),
                        );
                      },
                    ),
                    _buildHubCard(
                      context: context,
                      icon: Icons.queue_music_rounded,
                      title: AppLocale.tr('playlists'),
                      subtitle: '${userPlaylists.length} ${AppLocale.tr('playlists_count')}',
                      settings: settings,
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (nestedCtx) => PlaylistsOverviewScreen(
                              userPlaylists: userPlaylists,
                              onCreatePlaylist: onCreatePlaylist,
                              onDeletePlaylist: onDeletePlaylist,
                              onOpenPlaylist: (pl) {
                                Navigator.of(nestedCtx).push(
                                  MaterialPageRoute(
                                    builder: (_) => PlaylistDetailScreen(
                                      playlist: pl,
                                      onPlaySong: onPlaySong,
                                      onAddSongsToPlaylist: onAddSongsToPlaylist,
                                      onDeletePlaylist: () {
                                        Navigator.pop(nestedCtx);
                                        onDeletePlaylist(userPlaylists.indexOf(pl));
                                      },
                                      onAddToPlaylist: (_) {},
                                      onDeleteSongFromPlaylist: (songIdx) async {
                                        pl.songs.removeAt(songIdx);
                                        final prefs = await SharedPreferences.getInstance();
                                        await prefs.setString(
                                          'user_playlists',
                                          jsonEncode(userPlaylists.map((p) => p.toJson()).toList()),
                                        );
                                      },
                                      onDeleteSongFromStorage: (songIdx) async {
                                        final song = pl.songs[songIdx];
                                        pl.songs.removeAt(songIdx);
                                        librarySongs.removeWhere((s) => s.path == song.path);
                                        final prefs = await SharedPreferences.getInstance();
                                        await prefs.setString(
                                          'user_playlists',
                                          jsonEncode(userPlaylists.map((p) => p.toJson()).toList()),
                                        );
                                        await prefs.setString(
                                          'local_library_songs',
                                          jsonEncode(librarySongs.map((s) => s.toJson()).toList()),
                                        );
                                      },
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        );
                      },
                    ),
                    _buildHubCard(
                      context: context,
                      icon: Icons.person_rounded,
                      title: AppLocale.tr('artists'),
                      subtitle: '${artistMap.keys.length} ${AppLocale.tr('artists_count')}',
                      settings: settings,
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => ArtistsListScreen(
                              artistMap: artistMap,
                              onPlaySong: onPlaySong,
                              onShowSongMenu: onShowSongMenu,
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
        );
      },
    );
  }
}

// -------------------------------------------------------------
// Спільні елементи масових операцій (multi-select): панель виділення
// та діалог "додати вибрані до плейлиста"
// -------------------------------------------------------------

/// Top bar shown while the multi-select mode is active.
Widget buildMultiSelectBar({
  required int count,
  required VoidCallback onSelectAll,
  required VoidCallback onAddToPlaylist,
  required VoidCallback onDelete,
  required VoidCallback onClose,
}) {
  final settings = SettingsController.instance;
  final accent = settings.accentColor;
  return Container(
    margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: accent.withOpacity(0.14),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: accent.withOpacity(0.35), width: 1),
    ),
    child: Row(
      children: [
        IconButton(
          icon: Icon(Icons.close_rounded, color: settings.textColor, size: 22),
          onPressed: onClose,
        ),
        Expanded(
          child: Text(
            '${AppLocale.tr('selected')}: $count',
            style: TextStyle(
              color: settings.textColor,
              fontWeight: FontWeight.w800,
              fontSize: 14,
              fontFamily: 'sans-serif-rounded',
            ),
          ),
        ),
        IconButton(
          tooltip: AppLocale.tr('select_all'),
          icon: Icon(Icons.select_all_rounded, color: settings.textColor, size: 22),
          onPressed: onSelectAll,
        ),
        IconButton(
          tooltip: AppLocale.tr('add_selected_to_playlist'),
          icon: Icon(Icons.playlist_add_rounded, color: accent, size: 24),
          onPressed: count > 0 ? onAddToPlaylist : null,
        ),
        IconButton(
          tooltip: AppLocale.tr('delete_selected'),
          icon: const Icon(Icons.delete_outline_rounded,
              color: Colors.redAccent, size: 22),
          onPressed: count > 0 ? onDelete : null,
        ),
      ],
    ),
  );
}

/// Adds [songs] to one of [playlists]; persists via [onChanged] afterwards.
Future<void> showBulkAddToPlaylistDialog(
  BuildContext context, {
  required List<Song> songs,
  required List<CustomPlaylist> playlists,
  required VoidCallback onChanged,
}) async {
  if (songs.isEmpty) return;
  final settings = SettingsController.instance;
  await showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: settings.surfaceColor,
      title: Text(
        '${AppLocale.tr('add_to_playlist')} (${songs.length})',
        style: TextStyle(color: settings.textColor),
      ),
      content: playlists.isEmpty
          ? Text(AppLocale.tr('no_playlists'),
              style: TextStyle(color: settings.subTextColor))
          : SizedBox(
              width: double.maxFinite,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: playlists.length,
                itemBuilder: (c, idx) {
                  final pl = playlists[idx];
                  return ListTile(
                    title: Text(pl.name,
                        style: TextStyle(color: settings.textColor)),
                    trailing: Icon(Icons.add, color: settings.accentColor),
                    onTap: () {
                      Navigator.pop(ctx);
                      pl.songs.addAll(songs);
                      for (final s in songs) {
                        ListenTracker.instance.markAddedToPlaylist(s);
                      }
                      onChanged();
                    },
                  );
                },
              ),
            ),
    ),
  );
}

// -------------------------------------------------------------
// Екран: Вся музика
// -------------------------------------------------------------
class AllSongsScreen extends StatefulWidget {
  final List<Song> librarySongs;
  final ValueNotifier<Song?> currentPlayingSongNotifier;
  final Function(List<Song>, int) onPlaySong;
  final Function(Song, int) onShowSongMenu;
  final Future<void> Function(List<Song>) onDeleteSongs;
  final Future<void> Function(List<Song>) onAddSongsToPlaylist;

  const AllSongsScreen({
    super.key,
    required this.librarySongs,
    required this.currentPlayingSongNotifier,
    required this.onPlaySong,
    required this.onShowSongMenu,
    required this.onDeleteSongs,
    required this.onAddSongsToPlaylist,
  });

  @override
  State<AllSongsScreen> createState() => _AllSongsScreenState();
}

class _AllSongsScreenState extends State<AllSongsScreen> {
  static const int _pageSize = 30;

  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  String _searchQuery = '';
  int _visibleCount = _pageSize;

  // Multi-select state: long-press a row to enter selection mode.
  bool _selectionMode = false;
  final Set<Song> _selectedSongs = {};

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScrollNearBottom);
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_onScrollNearBottom)
      ..dispose();
    _searchController.dispose();
    super.dispose();
  }

  /// Local infinite scroll: reveals the next batch of already-loaded songs.
  /// (Local library lives on device — no network paging needed — but
  /// rendering 30 at a time keeps huge libraries smooth.)
  void _onScrollNearBottom() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 400) {
      setState(() => _visibleCount += _pageSize);
    }
  }

  // ---- Multi-select ----

  void _enterSelection(Song song) {
    setState(() {
      _selectionMode = true;
      _selectedSongs.add(song);
    });
  }

  void _toggleSelection(Song song) {
    setState(() {
      if (!_selectedSongs.remove(song)) {
        _selectedSongs.add(song);
      }
      if (_selectedSongs.isEmpty) _selectionMode = false;
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectedSongs.clear();
    });
  }

  /// Selects every library song matching the active search filter.
  void _selectAllVisible() {
    final q = _searchQuery.toLowerCase();
    setState(() {
      _selectedSongs
        ..clear()
        ..addAll(widget.librarySongs.where((song) {
          if (_searchQuery.isEmpty) return true;
          return song.title.toLowerCase().contains(q) ||
              song.artist.toLowerCase().contains(q);
        }));
    });
  }

  Future<void> _deleteSelected() async {
    final toDelete = _selectedSongs.toList();
    _exitSelection();
    await widget.onDeleteSongs(toDelete);
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsController.instance;
    final accent = settings.accentColor;

    final filteredSongs = widget.librarySongs.where((song) {
      if (_searchQuery.isEmpty) return true;
      final q = _searchQuery.toLowerCase();
      return song.title.toLowerCase().contains(q) ||
          song.artist.toLowerCase().contains(q);
    }).toList();

    String? headerCover;
    for (var s in widget.librarySongs) {
      if (s.artworkUrl != null && s.artworkUrl!.isNotEmpty) {
        headerCover = s.artworkUrl;
        break;
      }
    }

    return Scaffold(
      backgroundColor: settings.backgroundColor,
      body: CustomScrollView(
        key: const PageStorageKey('all_songs_scroll'),
        controller: _scrollController,
        slivers: [
          SliverToBoxAdapter(
            child: Stack(
              children: [
                SizedBox(
                  height: 310,
                  width: double.infinity,
                  child: headerCover != null
                      ? (headerCover.startsWith('http')
                          ? Image.network(headerCover, fit: BoxFit.cover)
                          : Image.file(File(headerCover), fit: BoxFit.cover))
                      : Container(
                          color: settings.surfaceColor,
                          child: Icon(Icons.music_note_rounded, size: 80, color: accent),
                        ),
                ),
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withOpacity(0.4),
                          Colors.transparent,
                          settings.backgroundColor.withOpacity(0.55),
                          settings.backgroundColor.withOpacity(0.9),
                          settings.backgroundColor,
                        ],
                        stops: const [0.0, 0.35, 0.70, 0.88, 1.0],
                      ),
                    ),
                  ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: Material(
                        color: Colors.black.withOpacity(0.45),
                        borderRadius: BorderRadius.circular(16),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => Navigator.pop(context),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 16),
                                const SizedBox(width: 6),
                                Text(
                                  AppLocale.tr('back'),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                    fontFamily: 'sans-serif-rounded',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 10,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        AppLocale.tr('all_music'),
                        style: TextStyle(
                          color: settings.textColor,
                          fontSize: 26,
                          fontWeight: FontWeight.w900,
                          fontFamily: 'sans-serif-rounded',
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(Icons.music_note_rounded, size: 16, color: settings.subTextColor),
                          const SizedBox(width: 4),
                          Text(
                            '${widget.librarySongs.length} ${AppLocale.tr('tracks_count')} ${AppLocale.tr('in_storage')}',
                            style: TextStyle(
                              color: settings.subTextColor,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              fontFamily: 'sans-serif-rounded',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Material(
                            color: settings.surfaceColor,
                            shape: const CircleBorder(),
                            child: IconButton(
                              icon: Icon(Icons.shuffle_rounded, color: accent, size: 22),
                              onPressed: widget.librarySongs.isEmpty
                                  ? null
                                  : () {
                                      final shuffled = List<Song>.from(widget.librarySongs)..shuffle();
                                      widget.onPlaySong(shuffled, 0);
                                    },
                            ),
                          ),
                          const SizedBox(width: 10),
                          Material(
                            color: accent,
                            shape: const CircleBorder(),
                            child: IconButton(
                              icon: const Icon(Icons.play_arrow_rounded, color: Colors.black, size: 28),
                              onPressed: widget.librarySongs.isEmpty
                                  ? null
                                  : () => widget.onPlaySong(widget.librarySongs, 0),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (_selectionMode)
            SliverToBoxAdapter(
              child: SafeArea(
                top: false,
                child: buildMultiSelectBar(
                  count: _selectedSongs.length,
                  onSelectAll: _selectAllVisible,
                  onAddToPlaylist: () async {
                    final toAdd = _selectedSongs.toList();
                    _exitSelection();
                    await widget.onAddSongsToPlaylist(toAdd);
                  },
                  onDelete: _deleteSelected,
                  onClose: _exitSelection,
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Container(
                decoration: BoxDecoration(
                  color: settings.surfaceColor,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: accent.withOpacity(0.12), width: 1),
                ),
                child: TextField(
                  controller: _searchController,
                  style: TextStyle(color: settings.textColor, fontSize: 14),
                  onChanged: (val) => setState(() {
                    _searchQuery = val.trim();
                    _visibleCount = _pageSize;
                  }),
                  decoration: InputDecoration(
                    hintText: AppLocale.tr('search_library_hint'),
                    hintStyle: TextStyle(color: settings.subTextColor, fontSize: 14),
                    prefixIcon: Icon(Icons.search_rounded, color: accent, size: 20),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: Icon(Icons.close_rounded, color: settings.subTextColor, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                          )
                        : null,
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ),
          ),
          filteredSongs.isEmpty
              ? SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Text(
                      _searchQuery.isEmpty ? AppLocale.tr('no_offline_tracks') : AppLocale.tr('empty_search'),
                      style: TextStyle(color: settings.subTextColor, fontFamily: 'sans-serif-rounded'),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final visible =
                            filteredSongs.take(_visibleCount).toList();
                        if (index >= visible.length) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16.0),
                            child: Center(
                              child: CircularProgressIndicator(color: accent),
                            ),
                          );
                        }
                        final song = visible[index];
                        final isSelected = _selectedSongs.contains(song);

                        return GestureDetector(
                          onLongPress: () => _enterSelection(song),
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              color: _selectionMode && isSelected
                                  ? accent.withOpacity(0.16)
                                  : settings.surfaceColor,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: _selectionMode && isSelected
                                    ? accent.withOpacity(0.6)
                                    : accent.withOpacity(0.06),
                                width: 1,
                              ),
                            ),
                            child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: Container(
                                  width: 46,
                                  height: 46,
                                  color: settings.backgroundColor,
                                  child: () {
                                    final art = song.artworkUrl;
                                    if (art == null || art.isEmpty) {
                                      return Icon(Icons.music_note_rounded, color: accent);
                                    }
                                    if (art.startsWith('http')) {
                                      return Image.network(art, fit: BoxFit.cover);
                                    }
                                    return Image.file(File(art), fit: BoxFit.cover);
                                  }(),
                                ),
                              ),
                              title: Text(
                                song.title,
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                  color: settings.textColor,
                                  fontFamily: 'sans-serif-rounded',
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => showArtistProfileSheet(
                                  context,
                                  song.artist,
                                  librarySongs: widget.librarySongs,
                                  onPlaySong: widget.onPlaySong,
                                ),
                                child: Text(
                                  song.artist.isEmpty ? AppLocale.tr('unknown_artist') : song.artist,
                                  style: TextStyle(
                                    color: settings.subTextColor,
                                    fontSize: 12,
                                    fontFamily: 'sans-serif-rounded',
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              trailing: _selectionMode
                                  ? Checkbox(
                                      value: isSelected,
                                      activeColor: accent,
                                      onChanged: (_) => _toggleSelection(song),
                                    )
                                  : IconButton(
                                      icon: Icon(Icons.more_vert_rounded, color: settings.subTextColor, size: 22),
                                      onPressed: () => widget.onShowSongMenu(song, widget.librarySongs.indexOf(song)),
                                    ),
                              onTap: () {
                                if (_selectionMode) {
                                  _toggleSelection(song);
                                  return;
                                }
                                final originalIndex = widget.librarySongs.indexOf(song);
                                widget.onPlaySong(widget.librarySongs, originalIndex >= 0 ? originalIndex : index);
                              },
                            ),
                          ),
                        );
                      },
                      childCount: filteredSongs.length > _visibleCount
                          ? _visibleCount + 1
                          : filteredSongs.length,
                    ),
                  ),
                ),
          const SliverToBoxAdapter(child: SizedBox(height: 90)),
        ],
      ),
    );
  }
}

// -------------------------------------------------------------
// Екран: Плейлисти
// -------------------------------------------------------------
class PlaylistsOverviewScreen extends StatelessWidget {
  final List<CustomPlaylist> userPlaylists;
  final VoidCallback onCreatePlaylist;
  final Function(CustomPlaylist) onOpenPlaylist;
  final ValueChanged<int> onDeletePlaylist;
  final void Function(int, String)? onRenamePlaylist;

  const PlaylistsOverviewScreen({
    super.key,
    required this.userPlaylists,
    required this.onCreatePlaylist,
    required this.onOpenPlaylist,
    required this.onDeletePlaylist,
    this.onRenamePlaylist,
  });

  void _showEditDialog(BuildContext context, int index, CustomPlaylist pl) {
    final controller = TextEditingController(text: pl.name);
    final settings = SettingsController.instance;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: settings.surfaceColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Редагувати плейлист',
          style: TextStyle(color: settings.textColor, fontWeight: FontWeight.bold),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: settings.textColor),
          decoration: InputDecoration(
            hintText: 'Введіть нову назву',
            hintStyle: TextStyle(color: settings.subTextColor),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: settings.accentColor),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Скасувати', style: TextStyle(color: settings.subTextColor)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: settings.accentColor,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () async {
              final newName = controller.text.trim();
              if (newName.isNotEmpty) {
                pl.name = newName;
                if (onRenamePlaylist != null) {
                  onRenamePlaylist!(index, newName);
                } else {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString(
                    'user_playlists',
                    jsonEncode(userPlaylists.map((p) => p.toJson()).toList()),
                  );
                }
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Зберегти', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showPlaylistOptions(BuildContext context, int index, CustomPlaylist pl) {
    final settings = SettingsController.instance;

    showModalBottomSheet(
      context: context,
      backgroundColor: settings.surfaceColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: settings.subTextColor.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    pl.name,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: settings.textColor,
                      fontFamily: 'sans-serif-rounded',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: settings.accentColor.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.edit_rounded, color: settings.accentColor),
                ),
                title: Text(
                  'Редагувати назву',
                  style: TextStyle(
                    color: settings.textColor,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'sans-serif-rounded',
                  ),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _showEditDialog(context, index, pl);
                },
              ),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
                ),
                title: const Text(
                  'Видалити плейлист',
                  style: TextStyle(
                    color: Colors.redAccent,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'sans-serif-rounded',
                  ),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  onDeletePlaylist(index);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsController.instance;
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
          AppLocale.tr('playlists'),
          style: TextStyle(
            color: settings.textColor,
            fontWeight: FontWeight.w900,
            fontFamily: 'sans-serif-rounded',
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.add_rounded, color: accent, size: 28),
            tooltip: AppLocale.tr('create_playlist'),
            onPressed: onCreatePlaylist,
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: userPlaylists.isEmpty
          ? Center(
              child: Text(
                AppLocale.tr('no_playlists'),
                style: TextStyle(color: settings.subTextColor, fontFamily: 'sans-serif-rounded'),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: userPlaylists.length,
              itemBuilder: (context, index) {
                final pl = userPlaylists[index];

                String? firstArt;
                for (var s in pl.songs) {
                  if (s.artworkUrl != null && s.artworkUrl!.isNotEmpty) {
                    firstArt = s.artworkUrl;
                    break;
                  }
                }

                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: settings.surfaceColor,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: accent.withOpacity(0.08), width: 1),
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        width: 48,
                        height: 48,
                        color: accent.withOpacity(0.14),
                        child: firstArt != null
                            ? (firstArt.startsWith('http')
                                ? Image.network(firstArt, fit: BoxFit.cover)
                                : Image.file(File(firstArt), fit: BoxFit.cover))
                            : Icon(Icons.queue_music_rounded, color: accent, size: 26),
                      ),
                    ),
                    title: Text(
                      pl.name,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: settings.textColor,
                        fontFamily: 'sans-serif-rounded',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${pl.songs.length} ${AppLocale.tr('tracks_count')}',
                      style: TextStyle(color: settings.subTextColor, fontSize: 12),
                    ),
                    trailing: IconButton(
                      icon: Icon(Icons.more_vert_rounded, color: settings.subTextColor),
                      onPressed: () => _showPlaylistOptions(context, index, pl),
                    ),
                    onTap: () => onOpenPlaylist(pl),
                  ),
                );
              },
            ),
    );
  }
}

// -------------------------------------------------------------
// Екран: Виконавці
// -------------------------------------------------------------
// -------------------------------------------------------------
// Екран: Список виконавців
// -------------------------------------------------------------
class ArtistsListScreen extends StatelessWidget {
  final Map<String, List<Song>> artistMap;
  final Function(List<Song>, int) onPlaySong;
  final Function(Song, int) onShowSongMenu;

  const ArtistsListScreen({
    super.key,
    required this.artistMap,
    required this.onPlaySong,
    required this.onShowSongMenu,
  });

  @override
  Widget build(BuildContext context) {
    final settings = SettingsController.instance;
    final accent = settings.accentColor;
    final artists = artistMap.keys.toList();

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
          AppLocale.tr('artists'),
          style: TextStyle(
            color: settings.textColor,
            fontWeight: FontWeight.w900,
            fontFamily: 'sans-serif-rounded',
          ),
        ),
      ),
      body: artists.isEmpty
          ? Center(
              child: Text(
                AppLocale.tr('empty_search'),
                style: TextStyle(color: settings.subTextColor, fontFamily: 'sans-serif-rounded'),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: artists.length,
              itemBuilder: (context, index) {
                final artistName = artists[index];
                final songs = artistMap[artistName] ?? [];

                String? artistCover;
                for (var s in songs) {
                  if (s.artworkUrl != null && s.artworkUrl!.isNotEmpty) {
                    artistCover = s.artworkUrl;
                    break;
                  }
                }

                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: settings.surfaceColor,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: accent.withOpacity(0.08), width: 1),
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    leading: ClipOval(
                      child: Container(
                        width: 48,
                        height: 48,
                        color: accent.withOpacity(0.14),
                        child: artistCover != null
                            ? (artistCover.startsWith('http')
                                ? Image.network(artistCover, fit: BoxFit.cover)
                                : Image.file(File(artistCover), fit: BoxFit.cover))
                            : Icon(Icons.person_rounded, color: accent, size: 26),
                      ),
                    ),
                    title: Text(
                      artistName,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: settings.textColor,
                        fontFamily: 'sans-serif-rounded',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${songs.length} ${AppLocale.tr('tracks_count')}',
                      style: TextStyle(color: settings.subTextColor, fontSize: 12),
                    ),
                    trailing: Icon(Icons.arrow_forward_ios_rounded, color: settings.subTextColor.withOpacity(0.5), size: 16),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ArtistDetailScreen(
                            artistName: artistName,
                            artistSongs: songs,
                            onPlaySong: onPlaySong,
                            onShowSongMenu: onShowSongMenu,
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
    );
  }
}

// -------------------------------------------------------------
// Екран: Деталі виконавця (Градієнтна шапка + треки цього артиста)
// -------------------------------------------------------------
class ArtistDetailScreen extends StatefulWidget {
  final String artistName;
  final List<Song> artistSongs;
  final Function(List<Song>, int) onPlaySong;
  final Function(Song, int) onShowSongMenu;

  const ArtistDetailScreen({
    super.key,
    required this.artistName,
    required this.artistSongs,
    required this.onPlaySong,
    required this.onShowSongMenu,
  });

  @override
  State<ArtistDetailScreen> createState() => _ArtistDetailScreenState();
}

class _ArtistDetailScreenState extends State<ArtistDetailScreen> {
  /// Local/playlist songs first, then top tracks fetched from the backend
  /// (`/api/artist?name=...`) — deduped — so the screen never stays empty
  /// when the artist has no local files but the server knows them.
  late final List<Song> _songs;

  ArtistProfile? _profile;
  bool _loading = true;
  bool _bioExpanded = false;

  @override
  void initState() {
    super.initState();
    _songs = List<Song>.from(widget.artistSongs);
    _fetchProfile();
  }

  Future<void> _fetchProfile() async {
    final profile = await MusicService.fetchArtistProfile(widget.artistName);
    if (!mounted) return;
    setState(() {
      _profile = profile;
      for (final track in profile.tracks) {
        final duplicate = _songs.any((e) {
          if (e.trackId != null &&
              e.trackId!.isNotEmpty &&
              track.trackId != null &&
              track.trackId!.isNotEmpty) {
            return e.trackId == track.trackId;
          }
          return e.title == track.title && e.artist == track.artist;
        });
        if (!duplicate) _songs.add(track);
      }
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsController.instance;
    final accent = settings.accentColor;

    String? headerCover;
    for (var s in _songs) {
      if (s.artworkUrl != null && s.artworkUrl!.isNotEmpty) {
        headerCover = s.artworkUrl;
        break;
      }
    }
    // Fall back to the Last.fm photo when no local artwork exists.
    headerCover ??= _profile?.imageUrl;

    return Scaffold(
      backgroundColor: settings.backgroundColor,
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Stack(
              children: [
                SizedBox(
                  height: 310,
                  width: double.infinity,
                  child: headerCover != null
                      ? (headerCover.startsWith('http')
                          ? Image.network(headerCover, fit: BoxFit.cover)
                          : Image.file(File(headerCover), fit: BoxFit.cover))
                      : Container(
                          color: settings.surfaceColor,
                          child: Icon(Icons.person_rounded, size: 80, color: accent),
                        ),
                ),
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withOpacity(0.4),
                          Colors.transparent,
                          settings.backgroundColor.withOpacity(0.55),
                          settings.backgroundColor.withOpacity(0.9),
                          settings.backgroundColor,
                        ],
                        stops: const [0.0, 0.35, 0.70, 0.88, 1.0],
                      ),
                    ),
                  ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: Material(
                        color: Colors.black.withOpacity(0.45),
                        borderRadius: BorderRadius.circular(16),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => Navigator.pop(context),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 16),
                                const SizedBox(width: 6),
                                Text(
                                  AppLocale.tr('back'),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                    fontFamily: 'sans-serif-rounded',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 10,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.artistName.isEmpty
                            ? AppLocale.tr('unknown_artist')
                            : widget.artistName,
                        style: TextStyle(
                          color: settings.textColor,
                          fontSize: 26,
                          fontWeight: FontWeight.w900,
                          fontFamily: 'sans-serif-rounded',
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(Icons.music_note_rounded, size: 16, color: settings.subTextColor),
                          const SizedBox(width: 4),
                          Text(
                            '${_songs.length} ${AppLocale.tr('tracks_count')}',
                            style: TextStyle(
                              color: settings.subTextColor,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              fontFamily: 'sans-serif-rounded',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Material(
                            color: settings.surfaceColor,
                            shape: const CircleBorder(),
                            child: IconButton(
                              icon: Icon(Icons.shuffle_rounded, color: accent, size: 22),
                              onPressed: _songs.isEmpty
                                  ? null
                                  : () {
                                      final shuffled = List<Song>.from(_songs)..shuffle();
                                      widget.onPlaySong(shuffled, 0);
                                    },
                            ),
                          ),
                          const SizedBox(width: 10),
                          Material(
                            color: accent,
                            shape: const CircleBorder(),
                            child: IconButton(
                              icon: const Icon(Icons.play_arrow_rounded, color: Colors.black, size: 28),
                              onPressed: _songs.isEmpty
                                  ? null
                                  : () => widget.onPlaySong(_songs, 0),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
          // Biography from the backend (Last.fm via /api/artist) — collapsed
          // by default so the track list stays the primary content.
          if (!_loading && (_profile?.bio.isNotEmpty ?? false))
            SliverToBoxAdapter(
              child: Container(
                margin: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                decoration: BoxDecoration(
                  color: settings.surfaceColor,
                  borderRadius: BorderRadius.circular(16),
                  border:
                      Border.all(color: accent.withOpacity(0.06), width: 1),
                ),
                child: Theme(
                  data: Theme.of(context)
                      .copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    initiallyExpanded: _bioExpanded,
                    onExpansionChanged: (v) =>
                        setState(() => _bioExpanded = v),
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.only(bottom: 10),
                    iconColor: accent,
                    collapsedIconColor: settings.subTextColor,
                    title: Text(
                      AppLocale.tr('biography'),
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: settings.textColor,
                        fontFamily: 'sans-serif-rounded',
                      ),
                    ),
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _profile!.bio,
                          style: TextStyle(
                            color: settings.subTextColor,
                            fontSize: 13,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_loading)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(top: 48),
                child: Center(child: CircularProgressIndicator()),
              ),
            )
          else if (_songs.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 40),
                child: Center(
                  child: Text(
                    AppLocale.tr('empty_search'),
                    style: TextStyle(
                      color: settings.subTextColor,
                      fontFamily: 'sans-serif-rounded',
                    ),
                  ),
                ),
              ),
            )
          else ...[
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final song = _songs[index];

                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: settings.surfaceColor,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: accent.withOpacity(0.06), width: 1),
                    ),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          width: 46,
                          height: 46,
                          color: settings.backgroundColor,
                          child: () {
                            final art = song.artworkUrl;
                            if (art == null || art.isEmpty) {
                              return Icon(Icons.music_note_rounded, color: accent);
                            }
                            if (art.startsWith('http')) {
                              return Image.network(art, fit: BoxFit.cover);
                            }
                            return Image.file(File(art), fit: BoxFit.cover);
                          }(),
                        ),
                      ),
                      title: Text(
                        song.title,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          color: settings.textColor,
                          fontFamily: 'sans-serif-rounded',
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => showArtistProfileSheet(
                          context,
                          song.artist,
                          librarySongs: _songs,
                          onPlaySong: widget.onPlaySong,
                        ),
                        child: Text(
                          song.artist.isEmpty ? AppLocale.tr('unknown_artist') : song.artist,
                          style: TextStyle(
                            color: settings.subTextColor,
                            fontSize: 12,
                            fontFamily: 'sans-serif-rounded',
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      trailing: IconButton(
                        icon: Icon(Icons.more_vert_rounded, color: settings.subTextColor, size: 22),
                        onPressed: () => widget.onShowSongMenu(song, index),
                      ),
                      onTap: () => widget.onPlaySong(_songs, index),
                    ),
                  );
                },
                childCount: _songs.length,
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 90)),
          ],
        ],
      ),
    );
  }
}

const BorderSide borderSideNone = BorderSide.none;

// -------------------------------------------------------------
// Екран: Деталі плейлиста (М'який градієнт шапки + меню дій)
// -------------------------------------------------------------


class SearchTab extends StatelessWidget {
  final List<Song> librarySongs;
  final Function(List<Song>, int) onSelectSong;
  final Function(Song, int) onShowSongMenu;

  const SearchTab({
    super.key,
    required this.librarySongs,
    required this.onSelectSong,
    required this.onShowSongMenu,
  });

  @override
  Widget build(BuildContext context) {
    final settings = SettingsController.instance;
    return Scaffold(
      backgroundColor: settings.backgroundColor,
      appBar: AppBar(
        title: Text(AppLocale.tr('search'), style: TextStyle(color: settings.textColor)),
        backgroundColor: settings.backgroundColor,
        elevation: 0,
      ),
      body: Center(
        child: Text(AppLocale.tr('search'), style: TextStyle(color: settings.subTextColor)),
      ),
    );
  }
}

// -------------------------------------------------------------
// Екран: Деталі плейлиста
// -------------------------------------------------------------
class PlaylistDetailScreen extends StatefulWidget {
  final CustomPlaylist playlist;
  final Function(List<Song>, int) onPlaySong;
  final VoidCallback onDeletePlaylist;
  final Function(Song) onAddToPlaylist;
  final Future<void> Function(int) onDeleteSongFromPlaylist;
  final Future<void> Function(int) onDeleteSongFromStorage;
  final Future<void> Function(String)? onRenamePlaylist;

  /// Bulk "add selected playlist tracks to another playlist" (optional).
  final Future<void> Function(List<Song>)? onAddSongsToPlaylist;

  const PlaylistDetailScreen({
    super.key,
    required this.playlist,
    required this.onPlaySong,
    required this.onDeletePlaylist,
    required this.onAddToPlaylist,
    required this.onDeleteSongFromPlaylist,
    required this.onDeleteSongFromStorage,
    this.onRenamePlaylist,
    this.onAddSongsToPlaylist,
  });

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  // Multi-select state: long-press a row to enter selection mode.
  bool _selectionMode = false;
  final Set<Song> _selectedSongs = {};

  void _enterSelection(Song song) {
    setState(() {
      _selectionMode = true;
      _selectedSongs.add(song);
    });
  }

  void _toggleSelection(Song song) {
    setState(() {
      if (!_selectedSongs.remove(song)) {
        _selectedSongs.add(song);
      }
      if (_selectedSongs.isEmpty) _selectionMode = false;
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectedSongs.clear();
    });
  }

  void _selectAll() {
    setState(() {
      _selectionMode = true;
      _selectedSongs
        ..clear()
        ..addAll(widget.playlist.songs);
    });
  }

  /// Removes the selected tracks from the playlist (descending indices, so
  /// the per-item callbacks stay valid while the list shrinks).
  Future<void> _deleteSelected() async {
    final indices = _selectedSongs
        .map((s) => widget.playlist.songs.indexOf(s))
        .where((i) => i >= 0)
        .toList()
      ..sort((a, b) => b.compareTo(a));
    _exitSelection();
    for (final i in indices) {
      await widget.onDeleteSongFromPlaylist(i);
    }
    if (mounted) setState(() {});
  }

  Future<void> _addSelectedToPlaylist() async {
    final toAdd = _selectedSongs.toList();
    final onAdd = widget.onAddSongsToPlaylist;
    _exitSelection();
    if (onAdd != null && toAdd.isNotEmpty) await onAdd(toAdd);
  }

  void _editPlaylistName(BuildContext context) {
    final controller = TextEditingController(text: widget.playlist.name);
    final settings = SettingsController.instance;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: settings.surfaceColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          AppLocale.tr('create_new_playlist'),
          style: TextStyle(color: settings.textColor, fontWeight: FontWeight.bold),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: settings.textColor),
          decoration: InputDecoration(
            hintText: AppLocale.tr('create_new_playlist'),
            hintStyle: TextStyle(color: settings.subTextColor),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: settings.accentColor),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(AppLocale.tr('cancel'), style: TextStyle(color: settings.subTextColor)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: settings.accentColor,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () async {
              final newName = controller.text.trim();
              if (newName.isNotEmpty) {
                setState(() {
                  widget.playlist.name = newName;
                });
                if (widget.onRenamePlaylist != null) {
                  await widget.onRenamePlaylist!(newName);
                }
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: Text(
              AppLocale.tr('save'),
              style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  void _showTopMenu(BuildContext context) {
    final settings = SettingsController.instance;

    showModalBottomSheet(
      context: context,
      backgroundColor: settings.surfaceColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: settings.subTextColor.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: settings.accentColor.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.edit_rounded, color: settings.accentColor),
                ),
                title: Text(
                  AppLocale.tr('create_new_playlist'),
                  style: TextStyle(
                    color: settings.textColor,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'sans-serif-rounded',
                  ),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _editPlaylistName(context);
                },
              ),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
                ),
                title: Text(
                  AppLocale.tr('delete_playlist'),
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'sans-serif-rounded',
                  ),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  widget.onDeletePlaylist();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showTrackMenu(BuildContext context, Song song, int index) {
    final settings = SettingsController.instance;

    showModalBottomSheet(
      context: context,
      backgroundColor: settings.surfaceColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16.0, horizontal: 8.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        width: 44,
                        height: 44,
                        color: settings.backgroundColor,
                        child: () {
                          final art = song.artworkUrl;
                          if (art == null || art.isEmpty) {
                            return Icon(Icons.music_note_rounded, color: settings.accentColor);
                          }
                          if (art.startsWith('http')) {
                            return Image.network(art, fit: BoxFit.cover);
                          }
                          return Image.file(File(art), fit: BoxFit.cover);
                        }(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            song.title,
                            style: TextStyle(
                              color: settings.textColor,
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                              fontFamily: 'sans-serif-rounded',
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            song.artist.isEmpty ? AppLocale.tr('unknown_artist') : song.artist,
                            style: TextStyle(color: settings.subTextColor, fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Divider(height: 1, color: settings.textColor.withOpacity(0.08)),
              const SizedBox(height: 6),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.orangeAccent.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.playlist_remove_rounded, color: Colors.orangeAccent),
                ),
                title: Text(
                  AppLocale.tr('delete_playlist'),
                  style: TextStyle(
                    color: settings.textColor,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'sans-serif-rounded',
                  ),
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  await widget.onDeleteSongFromPlaylist(index);
                  setState(() {});
                },
              ),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.delete_forever_rounded, color: Colors.redAccent),
                ),
                title: Text(
                  AppLocale.tr('delete_from_storage'),
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'sans-serif-rounded',
                  ),
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  await widget.onDeleteSongFromStorage(index);
                  setState(() {});
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsController.instance;
    final accent = settings.accentColor;

    String? headerCover;
    for (var s in widget.playlist.songs) {
      if (s.artworkUrl != null && s.artworkUrl!.isNotEmpty) {
        headerCover = s.artworkUrl;
        break;
      }
    }

    return Scaffold(
      backgroundColor: settings.backgroundColor,
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Stack(
              children: [
                SizedBox(
                  height: 310,
                  width: double.infinity,
                  child: headerCover != null
                      ? (headerCover.startsWith('http')
                          ? Image.network(headerCover, fit: BoxFit.cover)
                          : Image.file(File(headerCover), fit: BoxFit.cover))
                      : Container(
                          color: settings.surfaceColor,
                          child: Icon(Icons.queue_music_rounded, size: 80, color: accent),
                        ),
                ),
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withOpacity(0.4),
                          Colors.transparent,
                          settings.backgroundColor.withOpacity(0.55),
                          settings.backgroundColor.withOpacity(0.9),
                          settings.backgroundColor,
                        ],
                        stops: const [0.0, 0.35, 0.70, 0.88, 1.0],
                      ),
                    ),
                  ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: Material(
                        color: Colors.black.withOpacity(0.45),
                        borderRadius: BorderRadius.circular(16),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => Navigator.pop(context),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 16),
                                const SizedBox(width: 6),
                                Text(
                                  AppLocale.tr('back'),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                    fontFamily: 'sans-serif-rounded',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 10,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.playlist.name,
                        style: TextStyle(
                          color: settings.textColor,
                          fontSize: 26,
                          fontWeight: FontWeight.w900,
                          fontFamily: 'sans-serif-rounded',
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(Icons.music_note_rounded, size: 16, color: settings.subTextColor),
                          const SizedBox(width: 4),
                          Text(
                            '${widget.playlist.songs.length} ${AppLocale.tr('tracks_count')}',
                            style: TextStyle(
                              color: settings.subTextColor,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              fontFamily: 'sans-serif-rounded',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Material(
                            color: settings.surfaceColor,
                            shape: const CircleBorder(),
                            child: IconButton(
                              icon: Icon(Icons.shuffle_rounded, color: accent, size: 22),
                              onPressed: widget.playlist.songs.isEmpty
                                  ? null
                                  : () {
                                      final shuffled = List<Song>.from(widget.playlist.songs)..shuffle();
                                      widget.onPlaySong(shuffled, 0);
                                    },
                            ),
                          ),
                          const SizedBox(width: 10),
                          Material(
                            color: accent,
                            shape: const CircleBorder(),
                            child: IconButton(
                              icon: const Icon(Icons.play_arrow_rounded, color: Colors.black, size: 28),
                              onPressed: widget.playlist.songs.isEmpty
                                  ? null
                                  : () => widget.onPlaySong(widget.playlist.songs, 0),
                            ),
                          ),
                          const Spacer(),
                          Material(
                            color: settings.surfaceColor,
                            shape: const CircleBorder(),
                            child: IconButton(
                              icon: Icon(Icons.more_vert_rounded, color: settings.textColor, size: 22),
                              onPressed: () => _showTopMenu(context),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
          if (_selectionMode)
            SliverToBoxAdapter(
              child: SafeArea(
                top: false,
                child: buildMultiSelectBar(
                  count: _selectedSongs.length,
                  onSelectAll: _selectAll,
                  onAddToPlaylist: _addSelectedToPlaylist,
                  onDelete: _deleteSelected,
                  onClose: _exitSelection,
                ),
              ),
            ),
          widget.playlist.songs.isEmpty
              ? SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Text(
                      AppLocale.tr('no_offline_tracks'),
                      style: TextStyle(color: settings.subTextColor, fontFamily: 'sans-serif-rounded'),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final song = widget.playlist.songs[index];
                        final isSelected = _selectedSongs.contains(song);

                        return GestureDetector(
                          onLongPress: () => _enterSelection(song),
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              color: _selectionMode && isSelected
                                  ? accent.withOpacity(0.16)
                                  : settings.surfaceColor,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: _selectionMode && isSelected
                                    ? accent.withOpacity(0.6)
                                    : accent.withOpacity(0.06),
                                width: 1,
                              ),
                            ),
                            child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: Container(
                                  width: 46,
                                  height: 46,
                                  color: settings.backgroundColor,
                                  child: () {
                                    final art = song.artworkUrl;
                                    if (art == null || art.isEmpty) {
                                      return Icon(Icons.music_note_rounded, color: accent);
                                    }
                                    if (art.startsWith('http')) {
                                      return Image.network(art, fit: BoxFit.cover);
                                    }
                                    return Image.file(File(art), fit: BoxFit.cover);
                                  }(),
                                ),
                              ),
                              title: Text(
                                song.title,
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                  color: settings.textColor,
                                  fontFamily: 'sans-serif-rounded',
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => showArtistProfileSheet(
                                  context,
                                  song.artist,
                                  librarySongs: widget.playlist.songs,
                                  onPlaySong: widget.onPlaySong,
                                ),
                                child: Text(
                                  song.artist.isEmpty ? AppLocale.tr('unknown_artist') : song.artist,
                                  style: TextStyle(
                                    color: settings.subTextColor,
                                    fontSize: 12,
                                    fontFamily: 'sans-serif-rounded',
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              trailing: _selectionMode
                                  ? Checkbox(
                                      value: isSelected,
                                      activeColor: accent,
                                      onChanged: (_) => _toggleSelection(song),
                                    )
                                  : IconButton(
                                      icon: Icon(Icons.more_vert_rounded, color: settings.subTextColor, size: 22),
                                      onPressed: () => _showTrackMenu(context, song, index),
                                    ),
                              onTap: () {
                                if (_selectionMode) {
                                  _toggleSelection(song);
                                  return;
                                }
                                widget.onPlaySong(widget.playlist.songs, index);
                              },
                            ),
                          ),
                        );
                      },
                      childCount: widget.playlist.songs.length,
                    ),
                  ),
                ),
          const SliverToBoxAdapter(child: SizedBox(height: 90)),
        ],
      ),
    );
  }
}
