import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import 'dart:async';
import 'dsp_engine.dart';

Future<AudioHandler> initAudioService() async {
  return await AudioService.init(
    builder: () => MyAudioHandler(),
    config: AudioServiceConfig(
      androidNotificationChannelId: 'com.opentube.audiocontroller',
      androidNotificationChannelName: 'OpenTube Playback',
      androidNotificationIcon: 'mipmap/ic_launcher',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: false,
    ),
  );
}

class MyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  VoidCallback? onNextPressed;
  VoidCallback? onPrevPressed;
  Timer? _ticker;

  MyAudioHandler() {
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: AudioProcessingState.ready,
        playing: false,
      ),
    );

    _startPositionTicker();
  }

  void _startPositionTicker() {
    _ticker = Timer.periodic(const Duration(milliseconds: 800), (_) async {
      if (playbackState.value.playing) {
        final posMs = await DspEngine.instance.position();
        playbackState.add(playbackState.value.copyWith(
          updatePosition: Duration(milliseconds: posMs),
        ));
      }
    });
  }

  Future<void> updateMetadata(
    String title,
    String artist,
    String? artUrl, {
    Duration? duration,
  }) async {
    Uri? resolvedArtUri;
    if (artUrl != null && artUrl.isNotEmpty) {
      if (artUrl.startsWith('http')) {
        resolvedArtUri = Uri.parse(artUrl);
      } else {
        resolvedArtUri = Uri.file(artUrl);
      }
    }

    final item = MediaItem(
      id: title.hashCode.toString(),
      album: "OpenTube",
      title: title,
      artist: artist,
      artUri: resolvedArtUri,
      duration: duration ?? const Duration(minutes: 3, seconds: 30),
    );

    mediaItem.add(item);
  }

  void setDuration(Duration duration) {
    if (mediaItem.value != null) {
      mediaItem.add(mediaItem.value!.copyWith(duration: duration));
    }
  }

  @override
  Future<void> play() async {
    debugPrint('--> [AudioHandler] play() викликано');
    await DspEngine.instance.play();
    final posMs = await DspEngine.instance.position();

    playbackState.add(playbackState.value.copyWith(
      playing: true,
      speed: 1.0,
      processingState: AudioProcessingState.ready,
      updatePosition: Duration(milliseconds: posMs),
      controls: [
        MediaControl.skipToPrevious,
        MediaControl.pause,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
    ));
    debugPrint('--> [AudioHandler] playbackState переведено в playing: true');
  }

  @override
  Future<void> pause() async {
    debugPrint('--> [AudioHandler] pause() викликано');
    await DspEngine.instance.pause();
    final posMs = await DspEngine.instance.position();

    playbackState.add(playbackState.value.copyWith(
      playing: false,
      speed: 0.0,
      processingState: AudioProcessingState.ready,
      updatePosition: Duration(milliseconds: posMs),
      controls: [
        MediaControl.skipToPrevious,
        MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
    ));
  }

  @override
  Future<void> seek(Duration position) async {
    await DspEngine.instance.seekTo(position.inMilliseconds);
    playbackState.add(playbackState.value.copyWith(
      updatePosition: position,
    ));
  }

  @override
  Future<void> skipToNext() async {
    if (onNextPressed != null) onNextPressed!();
  }

  @override
  Future<void> skipToPrevious() async {
    if (onPrevPressed != null) onPrevPressed!();
  }

  @override
  Future<void> stop() async {
    await DspEngine.instance.pause();
    _ticker?.cancel();
    playbackState.add(playbackState.value.copyWith(
      playing: false,
      speed: 0.0,
      processingState: AudioProcessingState.idle,
    ));
    await super.stop();
  }
}