import 'dart:io';
import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

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
  final AudioPlayer _player = AudioPlayer();
  AudioPlayer get player => _player;

  VoidCallback? onNextPressed;
  VoidCallback? onPrevPressed;

  MyAudioHandler() {
    _initStreams();
  }

  void _initStreams() {
    _player.playbackEventStream.listen((event) {
      final playing = _player.playing;
      playbackState.add(playbackState.value.copyWith(
        playing: playing,
        controls: [
          MediaControl.skipToPrevious,
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {
          MediaAction.seek,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: const {
          ProcessingState.idle: AudioProcessingState.idle,
          ProcessingState.loading: AudioProcessingState.loading,
          ProcessingState.buffering: AudioProcessingState.buffering,
          ProcessingState.ready: AudioProcessingState.ready,
          ProcessingState.completed: AudioProcessingState.completed,
        }[_player.processingState]!,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
      ));
    });

    // Слухаємо позицію треку, щоб шторка плавно показувала прогрес
    _player.positionStream.listen((position) {
      final oldState = playbackState.value;
      playbackState.add(oldState.copyWith(
        updatePosition: position,
      ));
    });

    _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        skipToNext();
      }
    });
  }

  Future<void> updateMetadata(String title, String artist, String? artUrl, {Duration? duration}) async {
    mediaItem.add(MediaItem(
      id: title,
      album: "OpenTube",
      title: title,
      artist: artist,
      artUri: artUrl != null && artUrl.isNotEmpty ? Uri.parse(artUrl) : null,
      duration: duration, // <--- Передаємо загальну тривалість треку в шторку
    ));
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

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
    await _player.stop();
    await super.stop();
  }
}