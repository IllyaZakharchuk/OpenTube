import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
//import 'package:just_audio/just_audio.dart';
import 'dart:async';
import 'dsp_engine.dart';

Future<AudioHandler> initAudioService() async {
  return await AudioService.init(
    builder: () => MyAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.opentube.audiocontroller',
      androidNotificationChannelName: 'OpenTube Playback',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );
}

class MyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  VoidCallback? onNextPressed;
  VoidCallback? onPrevPressed;
  Timer? _ticker;

  MyAudioHandler() {
    _startPositionTicker();
  }

  void _startPositionTicker() {
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      if (playbackState.value.playing) {
        final posMs = await DspEngine.instance.position();
        playbackState.add(playbackState.value.copyWith(
          updatePosition: Duration(milliseconds: posMs),
        ));
      }
    });
  }

  Future<void> updateMetadata(String title, String artist, String? artUrl, {Duration? duration}) async {
    Uri? resolvedArtUri;
    if (artUrl != null && artUrl.isNotEmpty) {
      if (artUrl.startsWith('http')) {
        resolvedArtUri = Uri.parse(artUrl);
      } else {
        resolvedArtUri = Uri.file(artUrl);
      }
    }

    mediaItem.add(MediaItem(
      id: title,
      album: "OpenTube",
      title: title,
      artist: artist,
      artUri: resolvedArtUri,
      duration: duration ?? const Duration(minutes: 3, seconds: 30),
    ));
  }

  @override
  Future<void> play() async {
    await DspEngine.instance.play();
    playbackState.add(playbackState.value.copyWith(
      playing: true,
      controls: [
        MediaControl.skipToPrevious,
        MediaControl.pause,
        MediaControl.skipToNext,
      ],
    ));
  }

  @override
  Future<void> pause() async {
    await DspEngine.instance.pause();
    playbackState.add(playbackState.value.copyWith(
      playing: false,
      controls: [
        MediaControl.skipToPrevious,
        MediaControl.play,
        MediaControl.skipToNext,
      ],
    ));
  }

  @override
  Future<void> seek(Duration position) async {
    await DspEngine.instance.seekTo(position.inMilliseconds);
    playbackState.add(playbackState.value.copyWith(updatePosition: position));
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
    playbackState.add(playbackState.value.copyWith(playing: false));
    await super.stop();
  }
}