import 'package:opentube/models.dart';
import 'package:test/test.dart';

void main() {
  group('Song.sortByPlayCount', () {
    /// Sorts the list in place (descending) by playCount and returns it.
    List<Song> sorted(List<Song> songs) => Song.sortByPlayCount(songs);

    test('returns an empty list when input is empty', () {
      final result = sorted(<Song>[]);
      expect(result, isEmpty);
    });

    test('sorts tracks with higher play counts first', () {
      final songs = <Song>[
        Song(title: 'A', path: '', artist: 'a', playCount: 10),
        Song(title: 'B', path: '', artist: 'b', playCount: 3),
        Song(title: 'C', path: '', artist: 'c', playCount: 20),
      ];

      final result = sorted(songs);

      expect(result.map((s) => s.title), equals(['C', 'A', 'B']));
      for (int i = 1; i < result.length; i++) {
        expect(
            result[i - 1].playCount, greaterThanOrEqualTo(result[i].playCount));
      }
    });

    test('preserves original order for tracks with equal play counts', () {
      final songs = <Song>[
        Song(title: 'A', path: '', artist: 'a', playCount: 7),
        Song(title: 'B', path: '', artist: 'b', playCount: 7),
        Song(title: 'C', path: '', artist: 'c', playCount: 7),
      ];
      final result = sorted(songs);

      expect(result.map((s) => s.title), equals(['A', 'B', 'C']));
    });

    test('treats missing play counts as zero and keeps them at the bottom', () {
      final songs = <Song>[
        Song(title: 'A', path: '', artist: 'a', playCount: 2),
        Song(title: 'B', path: '', artist: 'b'),
        Song(title: 'C', path: '', artist: 'c', playCount: 0),
      ];

      final result = sorted(songs);

      expect(result.map((s) => s.title), equals(['A', 'B', 'C']));
      for (final song in result) {
        expect(song.playCount, greaterThanOrEqualTo(0));
      }
    });

    test('sorts with negative and zero play counts correctly', () {
      final songs = <Song>[
        Song(title: 'A', path: '', artist: 'a', playCount: -5),
        Song(title: 'B', path: '', artist: 'b', playCount: -1),
        Song(title: 'C', path: '', artist: 'c', playCount: 0),
      ];

      final result = sorted(songs);

      expect(result.map((s) => s.title), equals(['C', 'B', 'A']));
    });

    test('does not mutate the original list', () {
      final input = <Song>[
        Song(title: 'A', path: '', artist: 'a', playCount: 5),
        Song(title: 'B', path: '', artist: 'b', playCount: 2),
      ];
      final original = List<Song>.from(input);
      sorted(input);

      expect(input, equals(original));
    });
  });
}
