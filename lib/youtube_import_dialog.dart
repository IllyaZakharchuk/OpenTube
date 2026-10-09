import 'package:flutter/material.dart';

import 'settings_controller.dart';

/// Result returned by [YoutubeImportModeDialog.show]:
/// chosen storage mode + URL typed by the user.
class YoutubeImportResult {
  final bool isOnline;
  final String url;

  const YoutubeImportResult({required this.isOnline, required this.url});
}

/// Modal UI for choosing how an imported YouTube playlist should be stored:
/// as an online reference (no local audio files) or as offline local tracks.
class YoutubeImportModeDialog extends StatefulWidget {
  final String playlistTitle;
  final String importUrl;
  final bool isOnlineDefault;

  const YoutubeImportModeDialog({
    super.key,
    required this.playlistTitle,
    required this.importUrl,
    this.isOnlineDefault = true,
  });

  @override
  State<YoutubeImportModeDialog> createState() => _YoutubeImportModeDialogState();

  static Future<YoutubeImportResult?> show(
    BuildContext context, {
    required String playlistTitle,
    required String importUrl,
    bool isOnlineDefault = true,
  }) {
    return showDialog<YoutubeImportResult>(
      context: context,
      builder: (_) => YoutubeImportModeDialog(
        playlistTitle: playlistTitle,
        importUrl: importUrl,
        isOnlineDefault: isOnlineDefault,
      ),
    );
  }
}

class _YoutubeImportModeDialogState extends State<YoutubeImportModeDialog> {
  bool _isOnline = true;
  late final TextEditingController _urlController;

  @override
  void initState() {
    super.initState();
    _isOnline = widget.isOnlineDefault;
    _urlController = TextEditingController(text: widget.importUrl);
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  String get _typedUrl => _urlController.text.trim();
  bool get _isUrlValid => _typedUrl.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final settings = SettingsController.instance;
    final textColor = settings.textColor;
    final subTextColor = settings.subTextColor;
    final accent = settings.accentColor;

    return AlertDialog(
      backgroundColor: settings.surfaceColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(
        'Імпортувати плейлист',
        style: TextStyle(color: textColor, fontWeight: FontWeight.bold),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Плейлист: ${widget.playlistTitle}',
            style: TextStyle(color: textColor, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _urlController,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() {}),
            style: TextStyle(color: textColor),
            decoration: InputDecoration(
              labelText: 'Посилання на плейлист YouTube',
              hintText: 'https://music.youtube.com/playlist?list=...',
              labelStyle: TextStyle(color: subTextColor),
              hintStyle: TextStyle(color: subTextColor.withOpacity(0.6)),
              prefixIcon: Icon(Icons.link_rounded, color: accent),
              filled: true,
              fillColor: textColor.withOpacity(0.06),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
          ),
          const SizedBox(height: 16),
          RadioListTile<bool>(
            value: true,
            groupValue: _isOnline,
            activeColor: accent,
            title: Text('Зберегти онлайн', style: TextStyle(color: textColor)),
            onChanged: (value) {
              if (value != null) setState(() => _isOnline = value);
            },
          ),
          RadioListTile<bool>(
            value: false,
            groupValue: _isOnline,
            activeColor: accent,
            title: Text('Зберегти офлайн', style: TextStyle(color: textColor)),
            onChanged: (value) {
              if (value != null) setState(() => _isOnline = value);
            },
          ),
          const SizedBox(height: 12),
          Text(
            _isOnline
                ? 'Онлайн: плейлист буде зберігатися у зв’язку із сервером, без локальних аудіофайлів.'
                : 'Офлайн: треки будуть завантажені у локальну медіатеку.',
            style: TextStyle(color: subTextColor, height: 1.3, fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Скасувати', style: TextStyle(color: subTextColor)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: accent,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: _isUrlValid
              ? () => Navigator.pop(
                  context,
                  YoutubeImportResult(isOnline: _isOnline, url: _typedUrl),
                )
              : null,
          child: const Text('Продовжити', style: TextStyle(color: Colors.black)),
        ),
      ],
    );
  }
}
