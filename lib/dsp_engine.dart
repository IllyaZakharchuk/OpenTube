import 'package:flutter/services.dart';

enum BandType { peak, lowShelf, highShelf, lowPass, highPass }

class EqBand {
  final BandType type;
  final double freq;
  final double gainDb;
  final double q;
  final bool enabled;

  const EqBand({
    this.type = BandType.peak,
    required this.freq,
    this.gainDb = 0,
    this.q = 1.0,
    this.enabled = true,
  });

  EqBand copyWith({BandType? type, double? freq, double? gainDb, double? q, bool? enabled}) =>
      EqBand(
        type: type ?? this.type,
        freq: freq ?? this.freq,
        gainDb: gainDb ?? this.gainDb,
        q: q ?? this.q,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toMap() => {
        'type': type.index,
        'freq': freq,
        'gainDb': gainDb,
        'q': q,
        'enabled': enabled,
      };
}

class DspConfig {
  final bool enabled;
  final double preampDb;
  final List<EqBand> bands;
  final double tubeDrive;
  final double exciterAmount;
  final double stereoWidth;
  final double reverbMix;
  final double limiterCeilingDb;

  const DspConfig({
    this.enabled = true,
    this.preampDb = 0,
    this.bands = const [],
    this.tubeDrive = 0,
    this.exciterAmount = 0,
    this.stereoWidth = 0.34,
    this.reverbMix = 0.32,
    this.limiterCeilingDb = -1.5,
  });

  factory DspConfig.flat10() => DspConfig(
        bands: [
          for (final f in [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000])
            EqBand(freq: f.toDouble(), q: 1.41),
        ],
      );

  DspConfig copyWith({
    bool? enabled,
    double? preampDb,
    List<EqBand>? bands,
    double? tubeDrive,
    double? exciterAmount,
    double? stereoWidth,
    double? reverbMix,
    double? limiterCeilingDb,
  }) =>
      DspConfig(
        enabled: enabled ?? this.enabled,
        preampDb: preampDb ?? this.preampDb,
        bands: bands ?? this.bands,
        tubeDrive: tubeDrive ?? this.tubeDrive,
        exciterAmount: exciterAmount ?? this.exciterAmount,
        stereoWidth: stereoWidth ?? this.stereoWidth,
        reverbMix: reverbMix ?? this.reverbMix,
        limiterCeilingDb: limiterCeilingDb ?? this.limiterCeilingDb,
      );

  Map<String, dynamic> toMap() => {
        'enabled': enabled,
        'preampDb': preampDb,
        'bands': bands.map((b) => b.toMap()).toList(),
        'tubeDrive': tubeDrive,
        'exciterAmount': exciterAmount,
        'stereoWidth': stereoWidth,
        'reverbMix': reverbMix,
        'limiterCeilingDb': limiterCeilingDb,
      };
}

class DspEngine {
  static final DspEngine instance = DspEngine._();

  DspEngine._() {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'onTrackEnded') {
        onTrackEnded?.call();
      }
    });
  }

  static const _ch = MethodChannel('app/dsp');

  // ОСЬ ЦЬОГО РЯДКА ЗАРАЗ НЕ ВИСТАЧАЄ:
  VoidCallback? onTrackEnded;

  Future<void> load(String path) => _ch.invokeMethod('load', {'path': path});
  Future<void> play() => _ch.invokeMethod('play');
  Future<void> pause() => _ch.invokeMethod('pause');
  Future<void> seekTo(int ms) => _ch.invokeMethod('seekTo', {'ms': ms});
  Future<int> position() async => (await _ch.invokeMethod<int>('position')) ?? 0;
  Future<int> duration() async => (await _ch.invokeMethod<int>('duration')) ?? 0;

  Future<void> apply(DspConfig config) => _ch.invokeMethod('setConfig', config.toMap());
}