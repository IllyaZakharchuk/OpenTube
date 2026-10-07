import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dsp_engine.dart';

class EqualizerController extends ChangeNotifier {
  static final EqualizerController instance = EqualizerController._();
  EqualizerController._();

  final DspEngine _engine = DspEngine.instance;

  bool isEnabled = true;
  double tubeDrive = 0.0;      
  double exciterAmount = 0.20; 
  double stereoWidth = 0.42;   
  double reverbMix = 0.42;     
  double preampDb = 0.0;       

  List<EqBand> bands = DspConfig.flat10().bands;
  String currentPresetName = 'KZ ZS10 Pro X Stage';

  final Map<String, List<double>> presets = {
    'KZ ZS10 Pro X Stage': [3.2, 1.8, -1.5, 0.5, 2.5, 3.5, 2.0, -2.5, -1.0, 1.5],
    'Flat': [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    'Air & Clarity': [2.5, 2.0, 0.5, -1.5, -1.0, 0.5, 1.5, 3.0, 4.5, 6.0],
    'Punch Bass': [6.0, 5.0, 3.0, 0.5, -1.0, 0.0, 1.0, 2.0, 2.5, 2.0],
    'Rock / Metal': [4.5, 3.5, 1.5, -1.5, -1.0, 1.0, 2.5, 3.5, 4.0, 5.0],
  };

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    isEnabled = prefs.getBool('dsp_enabled') ?? true;
    tubeDrive = prefs.getDouble('dsp_tube') ?? 0.0;
    exciterAmount = prefs.getDouble('dsp_exciter') ?? 0.20;
    stereoWidth = prefs.getDouble('dsp_width') ?? 0.34;
    reverbMix = prefs.getDouble('dsp_reverb') ?? 0.32;
    preampDb = prefs.getDouble('dsp_preamp') ?? 0.0;
    currentPresetName = prefs.getString('dsp_preset') ?? 'KZ ZS10 Pro X Stage';

    final savedBands = prefs.getString('dsp_bands');
    if (savedBands != null) {
      final List decoded = jsonDecode(savedBands);
      bands = [
        for (int i = 0; i < decoded.length && i < bands.length; i++)
          bands[i].copyWith(gainDb: (decoded[i] as num).toDouble())
      ];
    } else if (presets.containsKey(currentPresetName)) {
      applyPresetGains(presets[currentPresetName]!);
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
    if (presets.containsKey(name)) {
      currentPresetName = name;
      applyPresetGains(presets[name]!);
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