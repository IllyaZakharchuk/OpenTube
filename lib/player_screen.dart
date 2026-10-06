import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'models.dart';

class PlayerScreen extends StatefulWidget {
  final ValueNotifier<Song?> songNotifier;
  final AudioPlayer audioPlayer;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;
  final VoidCallback onPrev;
  final VoidCallback onDownloadCurrent;

  const PlayerScreen({
    super.key,
    required this.songNotifier,
    required this.audioPlayer,
    required this.onPlayPause,
    required this.onNext,
    required this.onPrev,
    required this.onDownloadCurrent,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  bool isPlaying = false;
  bool isShuffle = false;
  LoopMode loopMode = LoopMode.off;
  Duration duration = Duration.zero;
  Duration position = Duration.zero;

  @override
  void initState() {
    super.initState();
    isPlaying = widget.audioPlayer.playing;
    isShuffle = widget.audioPlayer.shuffleModeEnabled;
    loopMode = widget.audioPlayer.loopMode;

    widget.audioPlayer.playerStateStream.listen((state) {
      if (!mounted) return;
      setState(() => isPlaying = state.playing);
    });

    widget.audioPlayer.durationStream.listen((d) {
      if (!mounted) return;
      setState(() => duration = d ?? Duration.zero);
    });

    widget.audioPlayer.positionStream.listen((p) {
      if (!mounted) return;
      setState(() => position = p);
    });

    widget.audioPlayer.shuffleModeEnabledStream.listen((enabled) {
      if (!mounted) return;
      setState(() => isShuffle = enabled);
    });

    widget.audioPlayer.loopModeStream.listen((mode) {
      if (!mounted) return;
      setState(() => loopMode = mode);
    });
  }

  String _formatDuration(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(d.inMinutes.remainder(60));
    final seconds = twoDigits(d.inSeconds.remainder(60));
    return "$minutes:$seconds";
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Song?>(
      valueListenable: widget.songNotifier,
      builder: (context, currentSong, child) {
        if (currentSong == null) {
          return const Scaffold(body: Center(child: Text('Немає активного треку')));
        }
        return Scaffold(
          body: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF2E1705), Color(0xFF141414), Color(0xFF0D0D0D)],
                stops: [0.0, 0.45, 1.0],
              ),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.keyboard_arrow_down, size: 34, color: Colors.white70),
                          onPressed: () => Navigator.pop(context),
                        ),
                        Text(
                          AppLocale.tr('now_playing'),
                          style: const TextStyle(fontSize: 13, letterSpacing: 2.0, fontWeight: FontWeight.w600, color: Colors.white60),
                        ),
                        IconButton(
                          icon: const Icon(Icons.download, size: 26, color: Colors.orangeAccent),
                          onPressed: widget.onDownloadCurrent,
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  Center(
                    child: Container(
                      width: 290,
                      height: 290,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [
                          BoxShadow(color: Colors.orangeAccent.withOpacity(0.18), blurRadius: 36, offset: const Offset(0, 14), spreadRadius: 2),
                          BoxShadow(color: Colors.black.withOpacity(0.7), blurRadius: 20, offset: const Offset(0, 10)),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: currentSong.artworkUrl != null && currentSong.artworkUrl!.isNotEmpty
                            ? Image.network(
                                currentSong.artworkUrl!,
                                fit: BoxFit.cover,
                                errorBuilder: (ctx, err, stack) => Container(color: const Color(0xFF222222), child: const Icon(Icons.music_note, size: 110, color: Colors.orangeAccent)),
                              )
                            : Container(color: const Color(0xFF222222), child: const Icon(Icons.music_note, size: 110, color: Colors.orangeAccent)),
                      ),
                    ),
                  ),
                  const Spacer(),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32.0),
                    child: Column(
                      children: [
                        Text(
                          currentSong.title,
                          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          currentSong.artist,
                          style: const TextStyle(fontSize: 16, color: Colors.white60),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: Column(
                      children: [
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            activeTrackColor: Colors.orangeAccent,
                            inactiveTrackColor: Colors.white12,
                            thumbColor: Colors.orangeAccent,
                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
                            trackHeight: 4.0,
                          ),
                          child: Slider(
                            min: 0,
                            max: duration.inSeconds.toDouble() > 0 ? duration.inSeconds.toDouble() : 1.0,
                            value: position.inSeconds.toDouble().clamp(0.0, duration.inSeconds.toDouble() > 0 ? duration.inSeconds.toDouble() : 1.0),
                            onChanged: (val) async {
                              await widget.audioPlayer.seek(Duration(seconds: val.toInt()));
                            },
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(_formatDuration(position), style: const TextStyle(color: Colors.white38, fontSize: 12, fontFeatures: [FontFeature.tabularFigures()])),
                              Text(_formatDuration(duration), style: const TextStyle(color: Colors.white38, fontSize: 12, fontFeatures: [FontFeature.tabularFigures()])),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        IconButton(
                          icon: Icon(Icons.shuffle, color: isShuffle ? Colors.orangeAccent : Colors.white38, size: 24),
                          onPressed: () async => await widget.audioPlayer.setShuffleModeEnabled(!isShuffle),
                        ),
                        IconButton(
                          iconSize: 42,
                          icon: const Icon(Icons.skip_previous, color: Colors.white),
                          onPressed: widget.onPrev,
                        ),
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.orangeAccent,
                            boxShadow: [
                              BoxShadow(color: Colors.orangeAccent.withOpacity(0.4), blurRadius: 18, offset: const Offset(0, 6)),
                            ],
                          ),
                          child: IconButton(
                            iconSize: 40,
                            color: Colors.black,
                            icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
                            onPressed: widget.onPlayPause,
                          ),
                        ),
                        IconButton(
                          iconSize: 42,
                          icon: const Icon(Icons.skip_next, color: Colors.white),
                          onPressed: widget.onNext,
                        ),
                        IconButton(
                          icon: Icon(loopMode == LoopMode.one ? Icons.repeat_one : Icons.repeat, color: loopMode != LoopMode.off ? Colors.orangeAccent : Colors.white38, size: 24),
                          onPressed: () async {
                            final next = loopMode == LoopMode.off ? LoopMode.one : LoopMode.off;
                            await widget.audioPlayer.setLoopMode(next);
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}