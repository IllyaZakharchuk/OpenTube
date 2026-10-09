import 'dart:async';
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
  final double punchAmount; // удар бочки 0..1
  final double airDb; // "повітря" (high-shelf), дБ
  final double lateScale; // хвіст реверберації 0..1
  final double centerCut; // віддаленість боків 0..1
  final double echoAmount; // ехо 0..1

  const DspConfig({
    this.enabled = true,
    this.preampDb = 0,
    this.bands = const [],
    this.tubeDrive = 0,
    this.exciterAmount = 0,
    this.stereoWidth = 0.34,
    this.reverbMix = 0.32,
    this.limiterCeilingDb = -1.5,
    this.punchAmount = 0.6,
    this.airDb = 2.5,
    this.lateScale = 0.5,
    this.centerCut = 0.6,
    this.echoAmount = 0.3,
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
    double? punchAmount,
    double? airDb,
    double? lateScale,
    double? centerCut,
    double? echoAmount,
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
        punchAmount: punchAmount ?? this.punchAmount,
        airDb: airDb ?? this.airDb,
        lateScale: lateScale ?? this.lateScale,
        centerCut: centerCut ?? this.centerCut,
        echoAmount: echoAmount ?? this.echoAmount,
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
        'punchAmount': punchAmount,
        'airDb': airDb,
        'lateScale': lateScale,
        'centerCut': centerCut,
        'echoAmount': echoAmount,
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

  VoidCallback? onTrackEnded;
  Timer? _fadeTimer;
  double _currentVolume = 1.0;

  double get currentVolume => _currentVolume;

  Future<void> load(String path) => _ch.invokeMethod('load', {'path': path});
  Future<void> play() => _ch.invokeMethod('play');
  Future<void> pause() => _ch.invokeMethod('pause');
  Future<void> seekTo(int ms) => _ch.invokeMethod('seekTo', {'ms': ms});
  Future<int> position() async => (await _ch.invokeMethod<int>('position')) ?? 0;
  Future<int> duration() async => (await _ch.invokeMethod<int>('duration')) ?? 0;

  Future<void> apply(DspConfig config) => _ch.invokeMethod('setConfig', config.toMap());

  /// Встановлення гучності на рівні аудіоканалу
  Future<void> setVolume(double volume) async {
    _currentVolume = volume.clamp(0.0, 1.0);
    try {
      await _ch.invokeMethod('setVolume', {'volume': _currentVolume});
    } catch (_) {
      // Якщо нативної підтримки setVolume поки немає в Kotlin,
      // виклик не ламатиме виконання
    }
  }

  /// Плавна анімація гучності від `from` до `to` за `durationMs`
  Future<void> fadeVolume({
    required double from,
    required double to,
    required int durationMs,
    VoidCallback? onComplete,
  }) async {
    _fadeTimer?.cancel();

    if (durationMs <= 0) {
      await setVolume(to);
      onComplete?.call();
      return;
    }

    const int stepMs = 20;
    final int totalSteps = (durationMs / stepMs).round().clamp(1, 1000);
    int currentStep = 0;

    await setVolume(from);

    final completer = Completer<void>();

    _fadeTimer = Timer.periodic(const Duration(milliseconds: stepMs), (timer) async {
      currentStep++;
      final double progress = (currentStep / totalSteps).clamp(0.0, 1.0);
      final double nextVol = from + (to - from) * progress;

      await setVolume(nextVol);

      if (currentStep >= totalSteps) {
        timer.cancel();
        await setVolume(to);
        onComplete?.call();
        if (!completer.isCompleted) completer.complete();
      }
    });

    return completer.future;
  }

  /// Плавна зупинка (затухання до 0 і pause)
  Future<void> smoothPause(int durationMs) async {
    await fadeVolume(
      from: _currentVolume,
      to: 0.0,
      durationMs: durationMs,
      onComplete: () async {
        await pause();
        await setVolume(1.0); // відновлюємо базову гучність
      },
    );
  }

  /// Плавний старт (гучність у 0 -> play -> наростання до 1.0)
  Future<void> smoothPlay(int durationMs) async {
    await setVolume(0.0);
    await play();
    await fadeVolume(
      from: 0.0,
      to: 1.0,
      durationMs: durationMs,
    );
  }
}