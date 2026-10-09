import 'package:flutter/foundation.dart';

import 'listening_store.dart';
import 'models.dart';

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
