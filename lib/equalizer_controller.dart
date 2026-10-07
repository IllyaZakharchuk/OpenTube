import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dsp_engine.dart';

class CustomPreset {
  final String name;
  final List<double> bands;
  final double tubeDrive;
  final double exciterAmount;
  final double stereoWidth;
  final double reverbMix;
  final double preampDb;

  CustomPreset({
    required this.name,
    required this.bands,
    required this.tubeDrive,
    required this.exciterAmount,
    required this.stereoWidth,
    required this.reverbMix,
    required this.preampDb,
  });

  Map<String, dynamic> toMap() => {
        'name': name,
        'bands': bands,
        'tubeDrive': tubeDrive,
        'exciterAmount': exciterAmount,
        'stereoWidth': stereoWidth,
        'reverbMix': reverbMix,
        'preampDb': preampDb,
      };

  factory CustomPreset.fromMap(Map<String, dynamic> map) => CustomPreset(
        name: map['name'] as String,
        bands: (map['bands'] as List).map((e) => (e as num).toDouble()).toList(),
        tubeDrive: (map['tubeDrive'] as num).toDouble(),
        exciterAmount: (map['exciterAmount'] as num).toDouble(),
        stereoWidth: (map['stereoWidth'] as num).toDouble(),
        reverbMix: (map['reverbMix'] as num).toDouble(),
        preampDb: (map['preampDb'] as num).toDouble(),
      );
}

class EqualizerController extends ChangeNotifier {
  static final EqualizerController instance = EqualizerController._();
  EqualizerController._();

  final DspEngine _engine = DspEngine.instance;

  bool isEnabled = true;
  double tubeDrive = 1.1;      // 0.0 .. 3.0
  double exciterAmount = 0.70; // 0.0 .. 1.0
  double stereoWidth = 2.0;    // 0.0 .. 2.0
  double reverbMix = 0.42;     // 0.0 .. 1.0
  double preampDb = 0.0;       // -6.0 .. +6.0 dB

  List<EqBand> bands = DspConfig.flat10().bands;
  String currentPresetName = 'KZ ZS10 Pro X Stage';

  final Map<String, List<double>> factoryPresets = {
    'Flat': [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    'Air & Clarity': [2.5, 2.0, 0.5, -1.5, -1.0, 0.5, 1.5, 3.0, 4.5, 6.0],
    'Punch Bass': [6.0, 5.0, 3.0, 0.5, -1.0, 0.0, 1.0, 2.0, 2.5, 2.0],
    'Rock / Metal': [4.5, 3.5, 1.5, -1.5, -1.0, 1.0, 2.5, 3.5, 4.0, 5.0],
  };

  Map<String, CustomPreset> customPresets = {};

  List<String> get allPresetNames => [
        ...factoryPresets.keys,
        ...customPresets.keys,
      ];

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    isEnabled = prefs.getBool('dsp_enabled') ?? true;
    tubeDrive = prefs.getDouble('dsp_tube') ?? 1.1;
    exciterAmount = prefs.getDouble('dsp_exciter') ?? 0.70;
    stereoWidth = prefs.getDouble('dsp_width') ?? 2.0;
    reverbMix = prefs.getDouble('dsp_reverb') ?? 0.42;
    preampDb = prefs.getDouble('dsp_preamp') ?? 0.0;
    currentPresetName = prefs.getString('dsp_preset') ?? 'Flat';

    // Завантаження кастомних пресетів
    final savedCustom = prefs.getString('dsp_custom_presets');
    if (savedCustom != null) {
      try {
        final Map<String, dynamic> decoded = jsonDecode(savedCustom);
        customPresets = decoded.map(
          (k, v) => MapEntry(k, CustomPreset.fromMap(v as Map<String, dynamic>)),
        );
      } catch (_) {}
    }

    final savedBands = prefs.getString('dsp_bands');
    if (savedBands != null) {
      final List decoded = jsonDecode(savedBands);
      bands = [
        for (int i = 0; i < decoded.length && i < bands.length; i++)
          bands[i].copyWith(gainDb: (decoded[i] as num).toDouble())
      ];
    } else if (factoryPresets.containsKey(currentPresetName)) {
      applyPresetGains(factoryPresets[currentPresetName]!);
    }

    notifyListeners();
    Future.microtask(() => applyAll());
  }

  Future<void> saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('dsp_enabled', isEnabled);
    await prefs.setDouble('dsp_tube', tubeDrive);
    await prefs.setDouble('dsp_exciter', exciterAmount);
    await prefs.setDouble('dsp_width', stereoWidth);
    await prefs.setDouble('dsp_reverb', reverbMix);
    await prefs.setDouble('dsp_preamp', preampDb);
    await prefs.setString('dsp_preset', currentPresetName);
    await prefs.setString('dsp_bands', jsonEncode(bands.map((b) => b.gainDb).toList()));
    await prefs.setString(
      'dsp_custom_presets',
      jsonEncode(customPresets.map((k, v) => MapEntry(k, v.toMap()))),
    );
  }

  void toggleEnabled(bool val) {
    isEnabled = val;
    notifyListeners();
    applyAll();
    saveSettings();
  }

  void setBandGain(int index, double gainDb) {
    if (index >= 0 && index < bands.length) {
      bands[index] = bands[index].copyWith(gainDb: gainDb);
      currentPresetName = 'Custom';
      notifyListeners();
      applyAll();
      saveSettings();
    }
  }

  void setExciter(double val) {
    exciterAmount = val;
    notifyListeners();
    applyAll();
    saveSettings();
  }

  void setStereoWidth(double val) {
    stereoWidth = val;
    notifyListeners();
    applyAll();
    saveSettings();
  }

  void setReverbMix(double val) {
    reverbMix = val;
    notifyListeners();
    applyAll();
    saveSettings();
  }

  void setTubeDrive(double val) {
    tubeDrive = val;
    notifyListeners();
    applyAll();
    saveSettings();
  }

  void applyPresetGains(List<double> gains) {
    bands = [
      for (int i = 0; i < bands.length; i++)
        bands[i].copyWith(gainDb: i < gains.length ? gains[i] : 0.0)
    ];
  }

  void selectPreset(String name) {
    if (factoryPresets.containsKey(name)) {
      currentPresetName = name;
      applyPresetGains(factoryPresets[name]!);
      notifyListeners();
      applyAll();
      saveSettings();
    } else if (customPresets.containsKey(name)) {
      final p = customPresets[name]!;
      currentPresetName = name;
      applyPresetGains(p.bands);
      tubeDrive = p.tubeDrive;
      exciterAmount = p.exciterAmount;
      stereoWidth = p.stereoWidth;
      reverbMix = p.reverbMix;
      preampDb = p.preampDb;
      notifyListeners();
      applyAll();
      saveSettings();
    }
  }

  void saveCurrentAsCustom(String name) {
    if (name.trim().isEmpty) return;
    final trimmed = name.trim();
    customPresets[trimmed] = CustomPreset(
      name: trimmed,
      bands: bands.map((b) => b.gainDb).toList(),
      tubeDrive: tubeDrive,
      exciterAmount: exciterAmount,
      stereoWidth: stereoWidth,
      reverbMix: reverbMix,
      preampDb: preampDb,
    );
    currentPresetName = trimmed;
    notifyListeners();
    saveSettings();
  }

  void deleteCustomPreset(String name) {
    if (customPresets.containsKey(name)) {
      customPresets.remove(name);
      if (currentPresetName == name) {
        currentPresetName = 'Flat';
        if (factoryPresets.containsKey(currentPresetName)) {
          applyPresetGains(factoryPresets[currentPresetName]!);
        }
      }
      notifyListeners();
      applyAll();
      saveSettings();
    }
  }

  Future<void> applyAll() async {
    try {
      final config = DspConfig(
        enabled: isEnabled,
        preampDb: preampDb,
        bands: bands,
        tubeDrive: tubeDrive,
        exciterAmount: exciterAmount,
        stereoWidth: stereoWidth,
        reverbMix: reverbMix,
      );
      await _engine.apply(config);
    } catch (e) {
      debugPrint('DSP engine apply error: $e');
    }
  }
}