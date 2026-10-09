import 'package:flutter/foundation.dart';

import 'dsp_engine.dart';
import 'listening_store.dart';
import 'models.dart';

/// Records listen sessions into SQLite. The strongest signals:
/// finish / repeat (+), skip in the first 30 seconds (−).
class ListenTracker {
  ListenTracker._();
  static final ListenTracker instance = ListenTracker._();

  Song? _current;
  String? _lastKey;
  bool _replayed = false;
  bool _naturalEnd = false;
  bool _favoritedThisPlay = false;

  Future<void> begin(Song song) async {
    await flush();
    final key = ListeningStore.trackKey(song);
    _replayed = _lastKey != null && _lastKey == key;
    _current = song;
    _naturalEnd = false;
    _favoritedThisPlay = await ListeningStore.instance.isFavorite(song);
  }

  void noteNaturalEnd() {
    _naturalEnd = true;
  }

  Future<bool> toggleFavorite(Song song) async {
    final liked = !await ListeningStore.instance.isFavorite(song);
    await ListeningStore.instance.setFavorite(song, liked);
    if (_current != null &&
        ListeningStore.trackKey(_current!) == ListeningStore.trackKey(song)) {
      _favoritedThisPlay = liked;
    }
    if (liked) {
      await ListeningStore.instance.insertEvent(ListeningEvent(
        trackId: song.trackId ?? ListeningStore.trackKey(song),
        artist: song.artist,
        title: song.title,
        percent: 0,
        listenedMs: 0,
        durationMs: 0,
        skipped: false,
        completed: false,
        replayed: false,
        favorited: true,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
    }
    return liked;
  }

  Future<bool> isFavorite(Song song) => ListeningStore.instance.isFavorite(song);

  Future<void> markAddedToPlaylist(Song song) async {
    await ListeningStore.instance.insertEvent(ListeningEvent(
      trackId: song.trackId ?? ListeningStore.trackKey(song),
      artist: song.artist,
      title: song.title,
      percent: 0.35,
      listenedMs: 0,
      durationMs: 0,
      skipped: false,
      completed: false,
      replayed: false,
      favorited: false,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  Future<void> flush() async {
    final song = _current;
    if (song == null) return;

    var listenedMs = 0;
    var durationMs = 0;
    try {
      listenedMs = await DspEngine.instance.position();
      durationMs = await DspEngine.instance.duration();
    } catch (e) {
      debugPrint('ListenTracker position: $e');
    }

    final percent = durationMs > 0
        ? (listenedMs / durationMs).clamp(0.0, 1.0)
        : 0.0;
    final skippedEarly = !_naturalEnd && listenedMs < 30000;
    final completed = _naturalEnd || percent >= 0.9;

    await ListeningStore.instance.insertEvent(ListeningEvent(
      trackId: song.trackId ?? ListeningStore.trackKey(song),
      artist: song.artist,
      title: song.title,
      percent: percent,
      listenedMs: listenedMs,
      durationMs: durationMs,
      skipped: skippedEarly,
      completed: completed,
      replayed: _replayed,
      favorited: _favoritedThisPlay,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));

    _lastKey = ListeningStore.trackKey(song);
    _current = null;
    _naturalEnd = false;
    _replayed = false;
    _favoritedThisPlay = false;
  }
}
