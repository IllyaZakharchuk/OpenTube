import 'language_screen.dart';
import 'theme_settings_screen.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'models.dart';
import 'audio_handler.dart';
import 'player_screen.dart';

late AudioHandler audioHandler;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  audioHandler = await initAudioService();
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
          home: const MainContainerScreen(), // або твій кореневий екран, що був тут раніше
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

class _MainContainerScreenState extends State<MainContainerScreen> {
  int _currentIndex = 2; // Відкривати "Інтернет"
  List<Song> librarySongs = [];
  List<CustomPlaylist> userPlaylists = [];
  bool isLoadingLibrary = true;

  final ValueNotifier<Song?> currentSongNotifier = ValueNotifier<Song?>(null);
  List<Song> currentQueue = [];
  int currentQueueIndex = -1;

  AudioPlayer get _player => (audioHandler as MyAudioHandler).player;

  @override
  void initState() {
    super.initState();
    _loadLocalData();

    final handler = audioHandler as MyAudioHandler;
    handler.onNextPressed = _playNext;
    handler.onPrevPressed = _playPrev;
  }

  Future<void> _loadLocalData() async {
    final prefs = await SharedPreferences.getInstance();

    final savedLang = prefs.getString('app_language');
    if (savedLang != null) appLanguageNotifier.value = savedLang;

    final savedTheme = prefs.getString('app_theme');
    if (savedTheme != null) appThemeNotifier.value = savedTheme;

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

    setState(() {
      isLoadingLibrary = false;
    });
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

  Future<void> _pickAudioFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: true,
      );
      if (result != null && result.files.isNotEmpty) {
        setState(() {
          for (var file in result.files) {
            if (file.path != null) {
              librarySongs.add(Song(
                title: file.name.replaceAll(RegExp(r'\.[^\/$.?#]+$'), ''),
                path: file.path!,
                artist: AppLocale.tr('local_track_artist'),
                isOnline: false,
              ));
            }
          }
        });
        await _saveLibrary();
      }
    } catch (e) {
      debugPrint('Pick file error: $e');
    }
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
      builder: (ctx) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 20.0, horizontal: 8.0),
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
      builder: (ctx) => AlertDialog(
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
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orangeAccent),
            onPressed: () async {
              if (controller.text.trim().isNotEmpty) {
                setState(() {
                  userPlaylists.add(CustomPlaylist(name: controller.text.trim(), songs: []));
                });
                await _savePlaylists();
              }
              Navigator.pop(ctx);
            },
            child: Text(AppLocale.tr('create'), style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _deleteLibrarySong(int index) async {
    setState(() {
      librarySongs.removeAt(index);
    });
    await _saveLibrary();
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
                      onTap: () async {
                        setState(() {
                          pl.songs.add(song);
                        });
                        await _savePlaylists();
                        Navigator.pop(ctx);
                      },
                    );
                  },
                ),
              ),
      ),
    );
  }

  void _playSong(List<Song> songs, int index) async {
    if (index < 0 || index >= songs.length) return;
    currentQueue = List.from(songs);
    currentQueueIndex = index;

    final song = songs[index];
    currentSongNotifier.value = song;

    final customHandler = audioHandler as MyAudioHandler;

    String finalUrl = song.path;
    if (song.isOnline) {
      if (song.trackId != null && song.trackId!.isNotEmpty) {
        finalUrl = MusicService.getStreamUrl(song.trackId!);
      } else if (!finalUrl.startsWith('http')) {
        debugPrint('--> [Player Error] Немає валідного URL або trackId!');
        return;
      }
    }

    await customHandler.updateMetadata(song.title, song.artist, song.artworkUrl);

    try {
      // 1. Повністю зупиняємо попередній трек
      await customHandler.player.stop();

      if (song.isOnline) {
        debugPrint('--> [Player] Завантаження стріму: $finalUrl');
        
        // 2. Встановлюємо URL (тут відбувається очікування завантаження з сервера)
        await customHandler.player.setUrl(
          finalUrl,
          headers: {
            'User-Agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36',
          },
        );
        
        // 3. Скидаємо позицію СТРОГО на початок треку (0:00)
        await customHandler.player.seek(Duration.zero);
      } else {
        debugPrint('--> [Player] Локальний файл: $finalUrl');
        await customHandler.player.setFilePath(finalUrl);
        await customHandler.player.seek(Duration.zero);
      }

      // 4. Запускаємо відтворення тільки зараз
      await audioHandler.play();
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
    if (currentQueue.isNotEmpty && currentQueueIndex + 1 < currentQueue.length) {
      _playSong(currentQueue, currentQueueIndex + 1);
    }
  }

  void _playPrev() {
    if (currentQueue.isNotEmpty && currentQueueIndex - 1 >= 0) {
      _playSong(currentQueue, currentQueueIndex - 1);
    }
  }

  void _openPlayerScreen() {
    if (currentSongNotifier.value == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (ctx) => PlayerScreen(
          songNotifier: currentSongNotifier,
          audioPlayer: _player,
          onPlayPause: () {
            if (_player.playing) {
              audioHandler.pause();
            } else {
              audioHandler.play();
            }
          },
          onNext: _playNext,
          onPrev: _playPrev,
          onDownloadCurrent: () {
            final cur = currentSongNotifier.value;
            if (cur != null) {
              _downloadSongToLibrary(cur);
            }
          },
        ),
      ),
    );
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
        onCreatePlaylist: _showCreatePlaylistDialog,
        onPlaySong: _playSong,
        onDeleteSong: _deleteLibrarySong,
        onAddToPlaylist: _showAddToPlaylistDialog,
        onDeletePlaylist: _deletePlaylist,
        onOpenPlaylist: (playlist) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (ctx) => PlaylistDetailScreen(
                playlist: playlist,
                onPlaySong: _playSong,
                onDeletePlaylist: () {
                  Navigator.pop(ctx);
                  setState(() => userPlaylists.remove(playlist));
                  _savePlaylists();
                },
                onAddToPlaylist: _showAddToPlaylistDialog,
                onDeleteSongFromPlaylist: (songIdx) async {
                  setState(() => playlist.songs.removeAt(songIdx));
                  await _savePlaylists();
                },
                onDeleteSongFromStorage: (songIdx) async {
                  final song = playlist.songs[songIdx];
                  setState(() {
                    playlist.songs.removeAt(songIdx);
                    librarySongs.removeWhere((s) => s.path == song.path);
                  });
                  await _savePlaylists();
                  await _saveLibrary();
                },
              ),
            ),
          );
        },
      ),
      SearchTab(
        librarySongs: librarySongs,
        onSelectSong: (songs, index) => _playSong(songs, index),
      ),
      DiscoverTab(
        onPlaySong: (songs, index) => _playSong(songs, index),
        onShowMenu: _showTrackMenu,
      ),
      const SettingsTab(),
    ];

    return Scaffold(
      body: Column(
        children: [
          Expanded(child: pages[_currentIndex]),
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
          NavigationDestination(icon: const Icon(Icons.library_music), label: AppLocale.tr('media')),
          NavigationDestination(icon: const Icon(Icons.search), label: AppLocale.tr('search')),
          NavigationDestination(icon: const Icon(Icons.language), label: AppLocale.tr('discover')),
          NavigationDestination(icon: const Icon(Icons.settings), label: AppLocale.tr('settings')),
        ],
      ),
    );
  }
}

// -------------------------------------------------------------
// Вкладка "Інтернет"
// -------------------------------------------------------------
class DiscoverTab extends StatefulWidget {
  final Function(List<Song>, int) onPlaySong;
  final ValueChanged<Song> onShowMenu;

  const DiscoverTab({super.key, required this.onPlaySong, required this.onShowMenu});

  @override
  State<DiscoverTab> createState() => _DiscoverTabState();
}

class _DiscoverTabState extends State<DiscoverTab> {
  final TextEditingController _searchController = TextEditingController();
  List<Song> _popularTracks = [];
  List<Song> _recommendedTracks = [];
  List<Song> _searchResults = [];
  bool _isLoadingContent = true;
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    _loadInitialMusic();
  }

  Future<void> _loadInitialMusic() async {
    try {
      final popular = await MusicService.getTrending();
      final recommended = await MusicService.getRecommendations();
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

  Future<void> _search(String query) async {
    final clean = query.trim();
    if (clean.isEmpty) return;

    setState(() {
      _isSearching = true;
      _searchResults = [];
    });

    final res = await MusicService.search(clean, limit: 25);
    if (mounted) {
      setState(() {
        _searchResults = res;
        _isSearching = false;
      });
    }
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
      body: ListView(
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
              decoration: InputDecoration(
                hintText: AppLocale.tr('search_web_hint'),
                hintStyle: TextStyle(color: SettingsController.instance.subTextColor),
                prefixIcon: Icon(Icons.search, color: SettingsController.instance.accentColor),
                suffixIcon: IconButton(
                  icon: Icon(Icons.send, color: SettingsController.instance.accentColor),
                  onPressed: () => _search(_searchController.text),
                ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          const SizedBox(height: 20),

          if (_isSearching)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: CircularProgressIndicator(color: SettingsController.instance.accentColor),
              ),
            )
          else if (_searchResults.isNotEmpty) ...[
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
              itemCount: _searchResults.length,
              itemBuilder: (context, index) {
                final song = _searchResults[index];
                return _buildTrackTile(song, _searchResults, index);
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
    );
  }

  Widget _buildTrackTile(Song song, List<Song> queue, int index) {
  final settings = SettingsController.instance;

  return Container(
    margin: const EdgeInsets.symmetric(vertical: 4),
    decoration: BoxDecoration(
      color: settings.surfaceColor,
      borderRadius: BorderRadius.circular(16),
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
      subtitle: Text(
        song.artist,
        style: TextStyle(
          color: settings.subTextColor,
          fontSize: 12,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            decoration: BoxDecoration(
              color: settings.accentColor,
              shape: BoxShape.circle,
            ),
            child: IconButton(
              iconSize: 22,
              icon: const Icon(Icons.play_arrow, color: Colors.black),
              onPressed: () => widget.onPlaySong(queue, index),
            ),
          ),
          IconButton(
            icon: Icon(Icons.more_vert, color: settings.subTextColor),
            onPressed: () => widget.onShowMenu(song),
          ),
        ],
      ),
      onTap: () => widget.onPlaySong(queue, index),
    ),
  );
  }
}

// ----------------------------------------------------
// Нижній міні-плеєр
// ----------------------------------------------------
class MiniPlayer extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final settings = SettingsController.instance;

    return ValueListenableBuilder<Song?>(
      valueListenable: currentSongNotifier,
      builder: (context, song, _) {
        if (song == null) return const SizedBox.shrink();

        return GestureDetector(
          onTap: onTap,
          child: Container(
            height: 64,
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 10),
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
                  onPressed: onPrev,
                ),
                StreamBuilder<PlaybackState>(
                  stream: audioHandler.playbackState,
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
                        onPressed: () {
                          if (playing) {
                            audioHandler.pause();
                          } else {
                            audioHandler.play();
                          }
                        },
                      ),
                    );
                  },
                ),
                IconButton(
                  icon: Icon(Icons.skip_next, color: settings.textColor, size: 22),
                  onPressed: onNext,
                ),
              ],
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
class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = SettingsController.instance;

    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) {
        // Отримуємо назву поточної мови для підпису
        String currentLangLabel = 'Українська 🇺🇦';
        if (settings.currentLang == 'en') currentLangLabel = 'English 🇬🇧';
        if (settings.currentLang == 'pl') currentLangLabel = 'Polski 🇵🇱';
        if (settings.currentLang == 'de') currentLangLabel = 'Deutsch 🇩🇪';
        if (settings.currentLang == 'es') currentLangLabel = 'Español 🇪🇸';

        // Отримуємо назву поточної теми фону
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
              Text(
                settings.tr('theme'),
                style: TextStyle(
                  color: settings.accentColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 10),
              Container(
                decoration: BoxDecoration(
                  color: settings.surfaceColor,
                  borderRadius: BorderRadius.circular(16),
                ),
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
                    Divider(height: 1, color: settings.textColor.withOpacity(0.08)),
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
              const SizedBox(height: 24),
              Text(
                'Про додаток',
                style: TextStyle(
                  color: settings.accentColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'OpenTube Music v0.9 Beta',
                style: TextStyle(fontWeight: FontWeight.w500, fontSize: 15, color: settings.textColor),
              ),
              const SizedBox(height: 6),
              Text(
                '• Підключено власний проксі-сервер Oracle\n• Захист від блокувань і 403 помилок :)',
                style: TextStyle(color: settings.subTextColor, height: 1.4, fontSize: 13),
              ),
            ],
          ),
        );
      },
    );
  }
}

// -------------------------------------------------------------
// Вкладки Медіатека та Локальний пошук
// -------------------------------------------------------------
class MediaLibraryTab extends StatelessWidget {
  final List<Song> librarySongs;
  final List<CustomPlaylist> userPlaylists;
  final ValueNotifier<Song?> currentPlayingSongNotifier;
  final bool isLoading;
  final VoidCallback onPickFiles;
  final VoidCallback onCreatePlaylist;
  final Function(List<Song>, int) onPlaySong;
  final ValueChanged<int> onDeleteSong;
  final ValueChanged<Song> onAddToPlaylist;
  final ValueChanged<int> onDeletePlaylist;
  final Function(CustomPlaylist) onOpenPlaylist;

  const MediaLibraryTab({
    super.key,
    required this.librarySongs,
    required this.userPlaylists,
    required this.currentPlayingSongNotifier,
    required this.isLoading,
    required this.onPickFiles,
    required this.onCreatePlaylist,
    required this.onPlaySong,
    required this.onDeleteSong,
    required this.onAddToPlaylist,
    required this.onDeletePlaylist,
    required this.onOpenPlaylist,
  });

  @override
Widget build(BuildContext context) {
  final settings = SettingsController.instance;

  return DefaultTabController(
    length: 2,
    child: Scaffold(
      backgroundColor: settings.backgroundColor,
      appBar: AppBar(
        title: Text(
          AppLocale.tr('my_library'),
          style: TextStyle(
            color: settings.textColor,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: settings.bgTheme == BgTheme.white
            ? settings.accentColor.withOpacity(0.12)
            : settings.backgroundColor,
        elevation: 0,
        iconTheme: IconThemeData(color: settings.textColor),
        bottom: TabBar(
          indicatorColor: settings.accentColor,
          labelColor: settings.accentColor,
          unselectedLabelColor: settings.subTextColor,
          tabs: [
            Tab(text: AppLocale.tr('offline_tracks')),
            Tab(text: AppLocale.tr('my_playlists')),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.add_circle_outline, color: settings.textColor),
            onPressed: () => showModalBottomSheet(
              context: context,
              backgroundColor: settings.surfaceColor,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              builder: (ctx) => Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListTile(
                      leading: Icon(Icons.audio_file, color: settings.accentColor),
                      title: Text(
                        AppLocale.tr('add_local_tracks'),
                        style: TextStyle(color: settings.textColor),
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        onPickFiles();
                      },
                    ),
                    ListTile(
                      leading: Icon(Icons.playlist_add, color: settings.accentColor),
                      title: Text(
                        AppLocale.tr('create_new_playlist'),
                        style: TextStyle(color: settings.textColor),
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        onCreatePlaylist();
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      body: TabBarView(
        children: [
          isLoading
              ? Center(
                  child: CircularProgressIndicator(color: settings.accentColor),
                )
              : librarySongs.isEmpty
                  ? Center(
                      child: Text(
                        AppLocale.tr('no_offline_tracks'),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: settings.subTextColor),
                      ),
                    )
                  : ValueListenableBuilder<Song?>(
                      valueListenable: currentPlayingSongNotifier,
                      builder: (context, currentPlayingSong, _) {
                        return ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          itemCount: librarySongs.length,
                          itemBuilder: (context, index) {
                            final song = librarySongs[index];
                            final isCurrent = currentPlayingSong?.path == song.path;
                            return Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              decoration: BoxDecoration(
                                color: isCurrent
                                    ? settings.accentColor.withOpacity(0.18)
                                    : settings.surfaceColor,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: ListTile(
                                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                                leading: Icon(
                                  Icons.music_note,
                                  color: settings.accentColor,
                                ),
                                title: Text(
                                  song.title,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14,
                                    color: isCurrent
                                        ? settings.accentColor
                                        : settings.textColor,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  song.artist,
                                  style: TextStyle(
                                    color: settings.subTextColor,
                                    fontSize: 12,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: IconButton(
                                  icon: Icon(Icons.more_vert, color: settings.subTextColor),
                                  onPressed: () => onAddToPlaylist(song),
                                ),
                                onTap: () => onPlaySong(librarySongs, index),
                              ),
                            );
                          },
                        );
                      },
                    ),
          userPlaylists.isEmpty
              ? Center(
                  child: Text(
                    AppLocale.tr('no_playlists'),
                    style: TextStyle(color: settings.subTextColor),
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                    childAspectRatio: 0.85,
                  ),
                  itemCount: userPlaylists.length,
                  itemBuilder: (context, index) {
                    final pl = userPlaylists[index];
                    return GestureDetector(
                      onTap: () => onOpenPlaylist(pl),
                      child: Container(
                        decoration: BoxDecoration(
                          color: settings.surfaceColor,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Container(
                                width: double.infinity,
                                decoration: BoxDecoration(
                                  color: settings.bgTheme == BgTheme.white
                                      ? settings.accentColor.withOpacity(0.12)
                                      : const Color(0xFF2C2C2C),
                                  borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                                ),
                                child: Icon(Icons.queue_music, size: 48, color: settings.accentColor),
                              ),
                            ),
                            Padding(
padding: const EdgeInsets.all(12.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    pl.name,
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15,
                                      color: settings.textColor,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${pl.songs.length} ${AppLocale.tr('tracks_count')}',
                                    style: TextStyle(color: settings.subTextColor, fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                          ], // закриття children зовнішнього Column
                        ),   // закриття зовнішнього Column
                      ),     // закриття Container
                    );       // закриття return GestureDetector
                  },
                ),
        ],
      ),
    ),
  );
}
}

class SearchTab extends StatefulWidget {
  final List<Song> librarySongs;
  final Function(List<Song>, int) onSelectSong;

  const SearchTab({super.key, required this.librarySongs, required this.onSelectSong});

  @override
  State<SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<SearchTab> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final filtered = widget.librarySongs
        .where((s) => s.title.toLowerCase().contains(_query.toLowerCase()))
        .toList();

    final settings = SettingsController.instance;

    return Scaffold(
      backgroundColor: settings.backgroundColor,
      appBar: AppBar(
        title: Text(
          AppLocale.tr('search'),
          style: TextStyle(color: settings.textColor, fontWeight: FontWeight.bold),
        ),
        backgroundColor: settings.backgroundColor,
        elevation: 0,
        iconTheme: IconThemeData(color: settings.textColor),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            TextField(
              onChanged: (val) => setState(() => _query = val),
              style: TextStyle(color: settings.textColor),
              decoration: InputDecoration(
                hintText: AppLocale.tr('search_library_hint'),
                hintStyle: TextStyle(color: settings.subTextColor),
                prefixIcon: Icon(Icons.search, color: settings.accentColor),
                filled: true,
                fillColor: settings.surfaceColor,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        AppLocale.tr('empty_search'),
                        style: TextStyle(color: settings.subTextColor),
                      ),
                    )
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final song = filtered[index];
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: settings.surfaceColor,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: ListTile(
                            leading: Icon(
                              Icons.music_note,
                              color: settings.accentColor,
                            ),
                            title: Text(
                              song.title,
                              style: TextStyle(
                                color: settings.textColor,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Text(
                              song.artist,
                              style: TextStyle(color: settings.subTextColor),
                            ),
                            trailing: Icon(
                              Icons.more_vert,
                              color: settings.subTextColor,
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class PlaylistDetailScreen extends StatelessWidget {
  final CustomPlaylist playlist;
  final Function(List<Song>, int) onPlaySong;
  final VoidCallback onDeletePlaylist;
  final Function(Song) onAddToPlaylist;
  final Future<void> Function(int) onDeleteSongFromPlaylist;
  final Future<void> Function(int) onDeleteSongFromStorage;

  const PlaylistDetailScreen({
    super.key,
    required this.playlist,
    required this.onPlaySong,
    required this.onDeletePlaylist,
    required this.onAddToPlaylist,
    required this.onDeleteSongFromPlaylist,
    required this.onDeleteSongFromStorage,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(playlist.name),
        actions: [
          IconButton(icon: const Icon(Icons.delete_outline, color: Colors.redAccent), onPressed: onDeletePlaylist),
        ],
      ),
      body: playlist.songs.isEmpty
          ? Center(child: Text(AppLocale.tr('no_offline_tracks'), style: const TextStyle(color: Colors.grey)))
          : ListView.builder(
              itemCount: playlist.songs.length,
              itemBuilder: (context, index) {
                final song = playlist.songs[index];
                return ListTile(
                  leading: const Icon(Icons.music_note, color: Colors.orangeAccent),
                  title: Text(song.title),
                  subtitle: Text(song.artist),
                  onTap: () => onPlaySong(playlist.songs, index),
                );
              },
            ),
    );
  }
}