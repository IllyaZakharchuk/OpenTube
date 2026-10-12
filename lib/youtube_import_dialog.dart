import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  final bool isOnlineDefault;

  const YoutubeImportModeDialog({
    super.key,
    required this.playlistTitle,
    this.isOnlineDefault = true,
  });

  @override
  State<YoutubeImportModeDialog> createState() => _YoutubeImportModeDialogState();

  static Future<YoutubeImportResult?> show(
    BuildContext context, {
    required String playlistTitle,
    bool isOnlineDefault = true,
  }) {
    return showDialog<YoutubeImportResult>(
      context: context,
      builder: (_) => YoutubeImportModeDialog(
        playlistTitle: playlistTitle,
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
    // The field always starts empty on purpose: the user pastes the link
    // with the one-tap clipboard button (or types it) instead of seeing a
    // stale/pre-filled URL from a previous import.
    _urlController = TextEditingController();
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
              suffixIcon: IconButton(
                icon: Icon(Icons.content_paste_rounded, color: accent),
                tooltip: 'Вставити з буфера',
                onPressed: () async {
                  // Clipboard reads are async and can fail (empty clipboard,
                  // platform restrictions, a hung platform channel) — never
                  // fail silently: catch errors, cap the wait, always give
                  // feedback and refresh the field + the validation state.
                  String text = '';
                  var failed = false;
                  try {
                    final data = await Clipboard.getData(Clipboard.kTextPlain)
                        .timeout(const Duration(seconds: 4));
                    text = (data?.text ?? '').trim();
                  } catch (e) {
                    failed = true;
                    debugPrint('Clipboard read error: $e');
                  }
                  if (!context.mounted) return;
                  if (failed || text.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(failed
                            ? 'Не вдалося прочитати буфер обміну'
                            : 'Буфер обміну порожній'),
                      ),
                    );
                    setState(() {});
                    return;
                  }
                  _urlController.text = text;
                  // Move the cursor to the end so the pasted link is fully
                  // visible and editable right away.
                  _urlController.selection =
                      TextSelection.collapsed(offset: text.length);
                  setState(() {});
                },
              ),
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
