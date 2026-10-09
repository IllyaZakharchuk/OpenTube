import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
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
  final double punchAmount;
  final double airDb;
  final double lateScale;
  final double centerCut;
  final double echoAmount;

  CustomPreset({
    required this.name,
    required this.bands,
    required this.tubeDrive,
    required this.exciterAmount,
    required this.stereoWidth,
    required this.reverbMix,
    required this.preampDb,
    this.punchAmount = 0.6,
    this.airDb = 2.5,
    this.lateScale = 0.5,
    this.centerCut = 0.6,
    this.echoAmount = 0.3,
  });

  CustomPreset withName(String newName) => CustomPreset(
        name: newName,
        bands: bands,
        tubeDrive: tubeDrive,
        exciterAmount: exciterAmount,
        stereoWidth: stereoWidth,
        reverbMix: reverbMix,
        preampDb: preampDb,
        punchAmount: punchAmount,
        airDb: airDb,
        lateScale: lateScale,
        centerCut: centerCut,
        echoAmount: echoAmount,
      );

  Map<String, dynamic> toMap() => {
        'name': name,
        'bands': bands,
        'tubeDrive': tubeDrive,
        'exciterAmount': exciterAmount,
        'stereoWidth': stereoWidth,
        'reverbMix': reverbMix,
        'preampDb': preampDb,
        'punchAmount': punchAmount,
        'airDb': airDb,
        'lateScale': lateScale,
        'centerCut': centerCut,
        'echoAmount': echoAmount,
      };

  // Старі пресети без нових полів отримують значення за замовчуванням
  factory CustomPreset.fromMap(Map<String, dynamic> map) => CustomPreset(
        name: map['name'] as String,
        bands: (map['bands'] as List).map((e) => (e as num).toDouble()).toList(),
        tubeDrive: (map['tubeDrive'] as num).toDouble(),
        exciterAmount: (map['exciterAmount'] as num).toDouble(),
        stereoWidth: (map['stereoWidth'] as num).toDouble(),
        reverbMix: (map['reverbMix'] as num).toDouble(),
        preampDb: (map['preampDb'] as num).toDouble(),
        punchAmount: (map['punchAmount'] as num?)?.toDouble() ?? 0.6,
        airDb: (map['airDb'] as num?)?.toDouble() ?? 2.5,
        lateScale: (map['lateScale'] as num?)?.toDouble() ?? 0.5,
        centerCut: (map['centerCut'] as num?)?.toDouble() ?? 0.6,
        echoAmount: (map['echoAmount'] as num?)?.toDouble() ?? 0.3,
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
  double punchAmount = 0.6;    // 0.0 .. 1.0  удар бочки
  double airDb = 2.5;          // 0.0 .. 6.0 dB  повітря (верхи)
  double lateScale = 0.5;      // 0.0 .. 1.0  хвіст реверберації
  double centerCut = 0.6;      // 0.0 .. 1.0  віддаленість боків
  double echoAmount = 0.3;     // 0.0 .. 1.0  ехо
  double limiterCeilingDb = -1.5; // -6.0 .. 0.0 dB  стеля лімітера (загальна, не в пресетах)
  double limiterReleaseMs = 80;   // 20 .. 300 мс
  double limiterLookaheadMs = 4;  // 1 .. 10 мс

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

  CustomPreset _snapshot(String name) => CustomPreset(
        name: name,
        bands: bands.map((b) => b.gainDb).toList(),
        tubeDrive: tubeDrive,
        exciterAmount: exciterAmount,
        stereoWidth: stereoWidth,
        reverbMix: reverbMix,
        preampDb: preampDb,
        punchAmount: punchAmount,
        airDb: airDb,
        lateScale: lateScale,
        centerCut: centerCut,
        echoAmount: echoAmount,
      );

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    isEnabled = prefs.getBool('dsp_enabled') ?? true;
    tubeDrive = prefs.getDouble('dsp_tube') ?? 1.1;
    exciterAmount = prefs.getDouble('dsp_exciter') ?? 0.70;
    stereoWidth = prefs.getDouble('dsp_width') ?? 2.0;
    reverbMix = prefs.getDouble('dsp_reverb') ?? 0.42;
    preampDb = prefs.getDouble('dsp_preamp') ?? 0.0;
    punchAmount = prefs.getDouble('dsp_punch') ?? 0.6;
    airDb = prefs.getDouble('dsp_air') ?? 2.5;
    lateScale = prefs.getDouble('dsp_late') ?? 0.5;
    centerCut = prefs.getDouble('dsp_center') ?? 0.6;
    echoAmount = prefs.getDouble('dsp_echo') ?? 0.3;
    limiterCeilingDb = prefs.getDouble('dsp_limiter') ?? -1.5;
    limiterReleaseMs = prefs.getDouble('dsp_lim_release') ?? 80;
    limiterLookaheadMs = prefs.getDouble('dsp_lim_look') ?? 4;
    currentPresetName = prefs.getString('dsp_preset') ?? 'Flat';

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
    await prefs.setDouble('dsp_punch', punchAmount);
    await prefs.setDouble('dsp_air', airDb);
    await prefs.setDouble('dsp_late', lateScale);
    await prefs.setDouble('dsp_center', centerCut);
    await prefs.setDouble('dsp_echo', echoAmount);
    await prefs.setDouble('dsp_limiter', limiterCeilingDb);
    await prefs.setDouble('dsp_lim_release', limiterReleaseMs);
    await prefs.setDouble('dsp_lim_look', limiterLookaheadMs);
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

  void setPunchAmount(double val) {
    punchAmount = val;
    notifyListeners();
    applyAll();
    saveSettings();
  }

  void setAirDb(double val) {
    airDb = val;
    notifyListeners();
    applyAll();
    saveSettings();
  }

  void setLateScale(double val) {
    lateScale = val;
    notifyListeners();
    applyAll();
    saveSettings();
  }

  void setCenterCut(double val) {
    centerCut = val;
    notifyListeners();
    applyAll();
    saveSettings();
  }

  void setEchoAmount(double val) {
    echoAmount = val;
    notifyListeners();
    applyAll();
    saveSettings();
  }

  void setLimiterRelease(double val) {
    limiterReleaseMs = val;
    notifyListeners();
    applyAll();
    saveSettings();
  }

  void setLimiterLookahead(double val) {
    limiterLookaheadMs = val;
    notifyListeners();
    applyAll();
    saveSettings();
  }

  void setLimiterCeiling(double val) {
    limiterCeilingDb = val;
    notifyListeners();
    applyAll();
    saveSettings();
  }

  void setPreampDb(double val) {
    preampDb = val;
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
      punchAmount = p.punchAmount;
      airDb = p.airDb;
      lateScale = p.lateScale;
      centerCut = p.centerCut;
      echoAmount = p.echoAmount;
      notifyListeners();
      applyAll();
      saveSettings();
    }
  }

  void saveCurrentAsCustom(String name) {
    if (name.trim().isEmpty) return;
    final trimmed = name.trim();
    customPresets[trimmed] = _snapshot(trimmed);
    currentPresetName = trimmed;
    notifyListeners();
    saveSettings();
  }

  void overwriteCustomPreset(String name) {
    if (!customPresets.containsKey(name)) return;
    customPresets[name] = _snapshot(name);
    currentPresetName = name;
    notifyListeners();
    saveSettings();
  }

  void renameCustomPreset(String oldName, String newName) {
    final trimmed = newName.trim();
    if (trimmed.isEmpty || oldName == trimmed || !customPresets.containsKey(oldName)) return;

    final old = customPresets.remove(oldName)!;
    customPresets[trimmed] = old.withName(trimmed);

    if (currentPresetName == oldName) {
      currentPresetName = trimmed;
    }
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

  // Експорт вибраного пресету у файл через системний діалог
  Future<bool> exportCustomPresetToFile(String presetName) async {
    try {
      // Якщо це не збережений кастомний пресет, беремо поточні налаштування
      final CustomPreset preset = customPresets[presetName] ?? _snapshot(presetName);

      final jsonStr = const JsonEncoder.withIndent('  ').convert(preset.toMap());
      final safeName = presetName.replaceAll(RegExp(r'[\\/:*?"<>| ]'), '_');
      final fileName = '${safeName}_preset.json';

      final resultPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Оберіть місце збереження пресету',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: utf8.encode(jsonStr),
      );

      return resultPath != null;
    } catch (e) {
      debugPrint('Export preset error: $e');
      return false;
    }
  }

  // Імпорт пресету з .json файлу через системний провідник
  Future<String?> importPresetFromFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (result == null || result.files.single.path == null) return null;

      final file = File(result.files.single.path!);
      final content = await file.readAsString();
      final Map<String, dynamic> data = jsonDecode(content);

      final imported = CustomPreset.fromMap(data);
      customPresets[imported.name] = imported;

      // Одразу обираємо та активуємо його
      selectPreset(imported.name);
      return imported.name;
    } catch (e) {
      debugPrint('Import preset error: $e');
      return null;
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
        punchAmount: punchAmount,
        airDb: airDb,
        lateScale: lateScale,
        centerCut: centerCut,
        echoAmount: echoAmount,
        limiterCeilingDb: limiterCeilingDb,
        limiterReleaseMs: limiterReleaseMs,
        limiterLookaheadMs: limiterLookaheadMs,
      );
      await _engine.apply(config);
    } catch (e) {
      debugPrint('DSP engine apply error: $e');
    }
  }
}