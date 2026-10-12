import 'dart:io';

import 'package:flutter/material.dart';

import 'models.dart';
import 'settings_controller.dart';

/// Placeholder artist names that should never open the profile sheet.
const Set<String> _placeholderArtists = {
  '',
  'Невідомий виконавець',
  'Unknown Artist',
  'Nieznany wykonawca',
  'Unbekannter Künstler',
  'Artista desconocido',
  'Локальний файл',
  'Local File',
  'Plik lokalny',
  'Lokale Datei',
  'Archivo local',
};

/// Opens the artist profile bottom sheet: bio + photo from the backend
/// (/api/artist), local library tracks by this artist and the artist's top
/// online tracks. Tapping a track plays it via [onPlaySong] (when provided)
/// and closes the sheet.
Future<void> showArtistProfileSheet(
  BuildContext context,
  String artistName, {
  List<Song> librarySongs = const [],
  void Function(List<Song>, int)? onPlaySong,
}) async {
  final name = artistName.trim();
  if (_placeholderArtists.contains(name)) return;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _ArtistProfileSheet(
      artistName: name,
      librarySongs: librarySongs,
      onPlaySong: onPlaySong,
    ),
  );
}

class _ArtistProfileSheet extends StatefulWidget {
  final String artistName;
  final List<Song> librarySongs;
  final void Function(List<Song>, int)? onPlaySong;

  const _ArtistProfileSheet({
    required this.artistName,
    required this.librarySongs,
    this.onPlaySong,
  });

  @override
  State<_ArtistProfileSheet> createState() => _ArtistProfileSheetState();
}

class _ArtistProfileSheetState extends State<_ArtistProfileSheet> {
  ArtistProfile? _profile;
  bool _bioExpanded = false;

  static bool _sameArtist(String a, String b) {
    final x = a.trim().toLowerCase();
    final y = b.trim().toLowerCase();
    if (x.isEmpty || y.isEmpty) return false;
    return x == y || x.contains(y) || y.contains(x);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final profile = await MusicService.fetchArtistProfile(widget.artistName);
    if (!mounted) return;
    setState(() => _profile = profile);
  }

  /// Local library tracks of this artist first, then online tracks from the
  /// backend, de-duplicated by trackId / title.
  List<Song> get _tracks {
    final local = widget.librarySongs
        .where((s) => _sameArtist(s.artist, widget.artistName))
        .toList();
    final seen = <String>{};
    final out = <Song>[...local];
    for (final s in local) {
      seen.add((s.trackId ?? '').toLowerCase());
      seen.add(s.title.trim().toLowerCase());
    }
    for (final s in _profile?.tracks ?? const <Song>[]) {
      final id = (s.trackId ?? '').toLowerCase();
      final title = s.title.trim().toLowerCase();
      if ((id.isNotEmpty && seen.contains(id)) ||
          (title.isNotEmpty && seen.contains(title))) {
        continue;
      }
      seen.add(id);
      seen.add(title);
      out.add(s);
    }
    return out;
  }

  String? get _cover {
    for (final s in widget.librarySongs) {
      if (_sameArtist(s.artist, widget.artistName) &&
          s.artworkUrl != null &&
          s.artworkUrl!.isNotEmpty) {
        return s.artworkUrl;
      }
    }
    final remote = _profile?.imageUrl;
    if (remote != null && remote.isNotEmpty) return remote;
    return null;
  }

  String _formatDuration(int? seconds) {
    if (seconds == null || seconds <= 0) return '';
    final d = Duration(seconds: seconds);
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = (d.inSeconds.remainder(60)).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsController.instance;
    final accent = settings.accentColor;
    final tracks = _tracks;
    final cover = _cover;
    final bio = (_profile?.bio ?? '').trim();
    final profileLoaded = _profile != null;

    return Container(
      height: MediaQuery.of(context).size.height * 0.78,
      decoration: BoxDecoration(
        color: settings.surfaceColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.45),
            blurRadius: 24,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(top: 12, bottom: 16),
                decoration: BoxDecoration(
                  color: settings.subTextColor.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  ClipOval(
                    child: Container(
                      width: 56,
                      height: 56,
                      color: accent.withOpacity(0.14),
                      child: cover != null
                          ? (cover.startsWith('http')
                              ? Image.network(cover, fit: BoxFit.cover)
                              : Image.file(File(cover), fit: BoxFit.cover))
                          : Icon(Icons.person_rounded, color: accent, size: 30),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.artistName,
                          style: TextStyle(
                            color: settings.textColor,
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                            fontFamily: 'sans-serif-rounded',
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${tracks.length} ${AppLocale.tr('tracks_count')}',
                          style: TextStyle(
                            color: settings.subTextColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    AppLocale.tr('biography'),
                    style: TextStyle(
                      color: settings.textColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      fontFamily: 'sans-serif-rounded',
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (!profileLoaded)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: accent,
                        ),
                      ),
                    )
                  else if (bio.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        AppLocale.tr('no_bio'),
                        style: TextStyle(
                          color: settings.subTextColor,
                          fontSize: 12.5,
                        ),
                      ),
                    )
                  else
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => _bioExpanded = !_bioExpanded),
                      child: Text(
                        bio,
                        style: TextStyle(
                          color: settings.subTextColor,
                          fontSize: 12.5,
                          height: 1.4,
                        ),
                        maxLines: _bioExpanded ? 12 : 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Divider(height: 1, color: settings.textColor.withOpacity(0.08)),

            Expanded(
              child: tracks.isEmpty
                  ? Center(
                      child: Text(
                        AppLocale.tr('empty_search'),
                        style: TextStyle(
                          color: settings.subTextColor,
                          fontFamily: 'sans-serif-rounded',
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      itemCount: tracks.length,
                      itemBuilder: (context, index) {
                        final song = tracks[index];
                        final onPlay = widget.onPlaySong;
                        final duration =
                            _formatDuration(song.durationSec);
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 2),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              width: 44,
                              height: 44,
                              color: settings.backgroundColor,
                              child: () {
                                final art = song.artworkUrl;
                                if (art == null || art.isEmpty) {
                                  return Icon(Icons.music_note_rounded,
                                      color: accent);
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
                              color: settings.textColor,
                              fontWeight: FontWeight.w700,
                              fontSize: 13.5,
                              fontFamily: 'sans-serif-rounded',
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            duration.isNotEmpty
                                ? '${song.artist} • $duration'
                                : song.artist,
                            style: TextStyle(
                              color: settings.subTextColor,
                              fontSize: 11.5,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Icon(
                            Icons.play_arrow_rounded,
                            color: onPlay != null
                                ? accent
                                : settings.subTextColor.withOpacity(0.4),
                          ),
                          onTap: onPlay == null
                              ? null
                              : () {
                                  Navigator.pop(context);
                                  onPlay(tracks, index);
                                },
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

