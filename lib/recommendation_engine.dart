import 'package:flutter/foundation.dart';

import 'listening_store.dart';
import 'models.dart';

/// Generic batched loader for infinite song lists.
///
/// Keeps already loaded [items], requests the next `pageSize` chunk via
/// [fetchPage] (which receives the current item count as `offset`) and
/// appends it. `hasMore=false` stops further requests; `isLoading` guards
/// against parallel fetches triggered by fast scrolling.
class PagedSongLoader extends ChangeNotifier {
  PagedSongLoader({
    required Future<List<Song>> Function(int offset, int limit) fetchPage,
    this.pageSize = 25,
  }) : _fetchPage = fetchPage;

  final Future<List<Song>> Function(int offset, int limit) _fetchPage;
  final int pageSize;

  final List<Song> items = [];
  bool hasMore = true;
  bool isLoading = false;
  Object? lastError;

  Future<void> loadMore() async {
    if (isLoading || !hasMore) return;
    isLoading = true;
    lastError = null;
    notifyListeners();
    try {
      final page = await _fetchPage(items.length, pageSize);
      final known = items
          .map((s) => s.trackId ?? '${s.artist}|${s.title}')
          .toSet();
      var added = 0;
      for (final song in page) {
        final key = song.trackId ?? '${song.artist}|${song.title}';
        if (known.add(key)) {
          items.add(song);
          added++;
        }
      }
      // A short (or empty) page means the backend has no more items.
      if (page.length < pageSize || added == 0 && page.isNotEmpty) {
        if (page.length < pageSize) hasMore = false;
      }
      if (page.isEmpty) hasMore = false;
    } catch (e) {
      lastError = e;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  void reset() {
    items.clear();
    hasMore = true;
    isLoading = false;
    lastError = null;
    notifyListeners();
  }
}

class RecommendationEngine {
  RecommendationEngine._();
  static final RecommendationEngine instance = RecommendationEngine._();

  Future<List<Song>> forYou({int limit = 20}) async {
    final seeds = await ListeningStore.instance.topSeeds(limit: 16);
    if (seeds.isEmpty) {
      debugPrint('Recommendations: no listening seeds yet, using fallback search');
      return MusicService.getRecommendations();
    }

    final exclude = await ListeningStore.instance.excludeIds();
    try {
      final fromServer = await MusicService.fetchPersonalized(
        seeds: seeds.map((s) => s.toJson()).toList(),
        excludeIds: exclude,
        limit: limit,
      );
      if (fromServer.isNotEmpty) return fromServer;
    } catch (e) {
      debugPrint('Personalized /api/recommend failed: $e');
    }

    return _clientSideBlend(seeds, exclude, limit);
  }

  Future<List<Song>> _clientSideBlend(
    List<TrackSeed> seeds,
    Set<String> exclude,
    int limit,
  ) async {
    final votes = <String, _Cand>{};
    final seedIds = seeds.map((s) => s.trackId).toSet();

    void addSongs(
      Iterable<Song> songs,
      TrackSeed seed, {
      required bool discovery,
    }) {
      for (final song in songs) {
        final id = song.trackId ?? '';
        if (id.isEmpty || exclude.contains(id) || seedIds.contains(id)) continue;
        final cand = votes.putIfAbsent(
          id,
          () => _Cand(song: song, discovery: discovery),
        );
        if (cand.seedIds.add(seed.trackId)) {
          cand.seedCount += 1;
        }
        cand.weight += seed.score;
        if (!discovery) cand.discovery = false;
      }
    }

    for (final seed in seeds.take(12)) {
      if (seed.trackId.isEmpty) continue;
      try {
        final radio = await MusicService.getRadio(seed.trackId, limit: 12);
        addSongs(radio, seed, discovery: false);
      } catch (e) {
        debugPrint('Radio for ${seed.trackId}: $e');
      }
      // Direct per-seed metadata search mirror of the server fix: keeps
      // underground/unofficial seeds (Lil Peep etc.) in the mix even when
      // radio/Last.fm/Deezer return nothing for them.
      try {
        final artist = seed.artist.trim();
        final title = seed.title.trim();
        final queries = <String>[
          if (artist.isNotEmpty && title.isNotEmpty) '$artist $title',
          if (artist.isNotEmpty) artist,
          if (title.isNotEmpty &&
              !artist.toLowerCase().contains(title.toLowerCase()))
            title,
        ];
        for (final q in queries) {
          final found = await MusicService.search(q, limit: 4);
          addSongs(found, seed, discovery: false);
          if (votes.length > limit * 12) break;
        }
      } catch (e) {
        debugPrint('Direct seed search ${seed.artist}: $e');
      }
    }

    for (final seed in seeds.take(8)) {
      try {
        final similar = await MusicService.lastFmSimilarTracks(
          artist: seed.artist,
          title: seed.title,
        );
        addSongs(similar, seed, discovery: false);
      } catch (e) {
        debugPrint('Last.fm similar ${seed.artist}: $e');
      }
    }

    for (final seed in seeds.take(8)) {
      try {
        final similar = await MusicService.deezerSimilar(
          artist: seed.artist,
          title: seed.title,
        );
        addSongs(similar, seed, discovery: true);
      } catch (e) {
        debugPrint('Deezer similar ${seed.artist}: $e');
      }
    }

    final ranked = votes.values.toList()
      ..sort((a, b) {
        final bySeeds = b.seedCount.compareTo(a.seedCount);
        if (bySeeds != 0) return bySeeds;
        return b.weight.compareTo(a.weight);
      });
    if (ranked.isEmpty) return MusicService.getRecommendations();

    final coreCount = (limit * 0.8).round().clamp(1, limit);
    final core = ranked.where((c) => !c.discovery).toList();
    final explore = ranked.where((c) => c.discovery).toList();

    final out = <Song>[];
    void take(List<_Cand> items, int n) {
      for (final c in items) {
        if (out.length >= n) return;
        if (out.any((s) => s.trackId == c.song.trackId)) continue;
        out.add(c.song);
      }
    }

    take(core, coreCount);
    take(explore, limit);
    take(ranked, limit);
    return out;
  }
}

class _Cand {
  _Cand({required this.song, required this.discovery});
  final Song song;
  final Set<String> seedIds = {};
  int seedCount = 0;
  double weight = 0;
  bool discovery;
}
