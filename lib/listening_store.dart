import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'models.dart';

class ListeningEvent {
  final int? id;
  final String trackId;
  final String artist;
  final String title;
  final double percent;
  final int listenedMs;
  final int durationMs;
  final bool skipped;
  final bool completed;
  final bool replayed;
  final bool favorited;
  final int createdAt;

  const ListeningEvent({
    this.id,
    required this.trackId,
    required this.artist,
    required this.title,
    required this.percent,
    required this.listenedMs,
    required this.durationMs,
    required this.skipped,
    required this.completed,
    required this.replayed,
    required this.favorited,
    required this.createdAt,
  });

  Map<String, Object?> toMap() => {
        'track_id': trackId,
        'artist': artist,
        'title': title,
        'percent': percent,
        'listened_ms': listenedMs,
        'duration_ms': durationMs,
        'skipped': skipped ? 1 : 0,
        'completed': completed ? 1 : 0,
        'replayed': replayed ? 1 : 0,
        'favorited': favorited ? 1 : 0,
        'created_at': createdAt,
      };
}

class TrackSeed {
  final String trackId;
  final String artist;
  final String title;
  final double score;
  final String? artworkUrl;

  const TrackSeed({
    required this.trackId,
    required this.artist,
    required this.title,
    required this.score,
    this.artworkUrl,
  });

  Map<String, dynamic> toJson() => {
        'id': trackId,
        'artist': artist,
        'title': title,
        'score': score,
      };
}

class ListeningStore {
  ListeningStore._();
  static final ListeningStore instance = ListeningStore._();

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    final dir = await getApplicationDocumentsDirectory();
    _db = await openDatabase(
      p.join(dir.path, 'listening_history.db'),
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE listening_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            track_id TEXT NOT NULL,
            artist TEXT NOT NULL,
            title TEXT NOT NULL,
            percent REAL NOT NULL,
            listened_ms INTEGER NOT NULL,
            duration_ms INTEGER NOT NULL,
            skipped INTEGER NOT NULL,
            completed INTEGER NOT NULL,
            replayed INTEGER NOT NULL,
            favorited INTEGER NOT NULL,
            created_at INTEGER NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_events_track ON listening_events(track_id)',
        );
        await db.execute(
          'CREATE INDEX idx_events_created ON listening_events(created_at)',
        );
        await db.execute('''
          CREATE TABLE favorites (
            track_key TEXT PRIMARY KEY,
            track_id TEXT,
            artist TEXT,
            title TEXT,
            artwork_url TEXT,
            path TEXT,
            is_online INTEGER,
            created_at INTEGER
          )
        ''');
      },
    );
    return _db!;
  }

  static String trackKey(Song song) {
    final id = song.trackId?.trim();
    if (id != null && id.isNotEmpty) return id;
    return '${song.artist.trim().toLowerCase()}|${song.title.trim().toLowerCase()}';
  }

  Future<void> insertEvent(ListeningEvent event) async {
    final db = await database;
    await db.insert('listening_events', event.toMap());
  }

  Future<bool> isFavorite(Song song) async {
    final db = await database;
    final rows = await db.query(
      'favorites',
      where: 'track_key = ?',
      whereArgs: [trackKey(song)],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> setFavorite(Song song, bool liked) async {
    final db = await database;
    final key = trackKey(song);
    if (liked) {
      await db.insert(
        'favorites',
        {
          'track_key': key,
          'track_id': song.trackId,
          'artist': song.artist,
          'title': song.title,
          'artwork_url': song.artworkUrl,
          'path': song.path,
          'is_online': song.isOnline ? 1 : 0,
          'created_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } else {
      await db.delete('favorites', where: 'track_key = ?', whereArgs: [key]);
    }
  }

  /// Already listened through or skipped in the first 30s — keep out of recs.
  Future<Set<String>> excludeIds() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT DISTINCT track_id FROM listening_events
      WHERE track_id != ""
        AND (skipped = 1 OR completed = 1 OR percent >= 0.45)
    ''');
    return rows.map((r) => r['track_id'] as String).toSet();
  }

  /// Highest-scoring recent tracks. Recency half-life ≈ 14 days.
  Future<List<TrackSeed>> topSeeds({int limit = 16}) async {
    final db = await database;
    final cutoff = DateTime.now()
        .subtract(const Duration(days: 90))
        .millisecondsSinceEpoch;
    final rows = await db.query(
      'listening_events',
      where: 'created_at >= ?',
      whereArgs: [cutoff],
      orderBy: 'created_at DESC',
    );
    if (rows.isEmpty) return [];

    final now = DateTime.now().millisecondsSinceEpoch;
    final scores = <String, _Agg>{};

    for (final row in rows) {
      final id = (row['track_id'] as String?) ?? '';
      if (id.isEmpty) continue;

      final createdAt = row['created_at'] as int;
      final ageDays = (now - createdAt) / (1000 * 60 * 60 * 24);
      final decay = _halfLife(ageDays, 14);

      final percent = (row['percent'] as num).toDouble();
      final skipped = (row['skipped'] as int) == 1;
      final completed = (row['completed'] as int) == 1;
      final replayed = (row['replayed'] as int) == 1;
      final favorited = (row['favorited'] as int) == 1;
      final listenedMs = row['listened_ms'] as int;

      var raw = percent;
      if (completed) raw += 3.0;
      if (replayed) raw += 4.0;
      if (favorited) raw += 5.0;
      if (skipped && listenedMs < 30000) raw -= 4.0;

      final agg = scores.putIfAbsent(
        id,
        () => _Agg(
          trackId: id,
          artist: row['artist'] as String,
          title: row['title'] as String,
        ),
      );
      agg.score += raw * decay;
    }

    final favRows = await db.query('favorites');
    for (final row in favRows) {
      final id = (row['track_id'] as String?) ?? '';
      if (id.isEmpty) continue;
      final agg = scores.putIfAbsent(
        id,
        () => _Agg(
          trackId: id,
          artist: row['artist'] as String? ?? '',
          title: row['title'] as String? ?? '',
        ),
      );
      agg.score += 2.5;
    }

    final ranked = scores.values.where((a) => a.score > 0).toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    return ranked.take(limit).map((a) {
      return TrackSeed(
        trackId: a.trackId,
        artist: a.artist,
        title: a.title,
        score: a.score,
      );
    }).toList();
  }

  /// Number of listen events per track, used for sorting tracks by listens.
  Future<Map<String, int>> getPlayCounts() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT track_id, COUNT(*) AS cnt
      FROM listening_events
      WHERE track_id != ''
      GROUP BY track_id
      ORDER BY cnt DESC
    ''');
    return {for (final r in rows) (r['track_id'] as String): (r['cnt'] as int)};
  }

  /// Fetches songs that exist locally and attaches their listen counts.
  Future<List<Song>> loadSongsWithPlayCounts(List<Song> songs) async {
    final playCounts = await getPlayCounts();
    return songs.map((song) {
      final count = playCounts[song.trackId ?? ''];
      return song.copyWith(playCount: count ?? 0);
    }).toList();
  }
}

class _Agg {
  _Agg({required this.trackId, required this.artist, required this.title});
  final String trackId;
  final String artist;
  final String title;
  double score = 0;
}

double _halfLife(double ageDays, double halfLifeDays) {
  if (ageDays <= 0) return 1;
  return 1 / (1 + ageDays / halfLifeDays);
}
