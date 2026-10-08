import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import 'models.dart';
import 'settings_controller.dart';

class PlayerScreen extends StatefulWidget {
  final ValueNotifier<Song?> songNotifier;
  final AudioHandler audioHandler;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;
  final VoidCallback onPrev;
  final VoidCallback onDownloadCurrent;
  final VoidCallback onToggleShuffle;
  final VoidCallback onToggleRepeat;
  final bool isShuffle;
  final bool isRepeat;

  const PlayerScreen({
    super.key,
    required this.songNotifier,
    required this.audioHandler,
    required this.onPlayPause,
    required this.onNext,
    required this.onPrev,
    required this.onDownloadCurrent,
    required this.onToggleShuffle,
    required this.onToggleRepeat,
    this.isShuffle = false,
    this.isRepeat = false,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> with TickerProviderStateMixin {
  bool isPlaying = false;
  late bool isShuffleActive;
  late bool isRepeatActive;
  Duration duration = const Duration(minutes: 3, seconds: 30);
  Duration position = Duration.zero;

  late final AnimationController _rotationController;
  late final AnimationController _morphController;
  late final AnimationController _beatController;
  late final AnimationController _fluidController;

  StreamSubscription<PlaybackState>? _playbackSub;
  StreamSubscription<MediaItem?>? _mediaItemSub;

  @override
  void initState() {
    super.initState();
    isShuffleActive = widget.isShuffle;
    isRepeatActive = widget.isRepeat;
    isPlaying = widget.audioHandler.playbackState.value.playing;

    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 26),
    );

    _morphController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
      value: isPlaying ? 1.0 : 0.0,
    );

    _beatController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );

    _fluidController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    );

    if (isPlaying) {
      _rotationController.repeat();
      _beatController.repeat(reverse: true);
      _fluidController.repeat();
    }

    _playbackSub = widget.audioHandler.playbackState.listen((state) {
      if (!mounted) return;
      final playing = state.playing;

      // Оновлюємо стан, якщо аудіосервіс змінив статус ззовні
      if (isPlaying != playing) {
        setState(() {
          isPlaying = playing;
          _updateAnimations(playing);
        });
      }

      setState(() {
        position = state.position;
      });
    });

    _mediaItemSub = widget.audioHandler.mediaItem.listen((item) {
      if (!mounted) return;
      if (item?.duration != null) {
        setState(() => duration = item!.duration!);
      }
    });
  }

  void _updateAnimations(bool playing) {
    if (playing) {
      _morphController.forward();
      if (!_rotationController.isAnimating) _rotationController.repeat();
      if (!_beatController.isAnimating) _beatController.repeat(reverse: true);
      if (!_fluidController.isAnimating) _fluidController.repeat();
    } else {
      _morphController.reverse();
      _rotationController.stop();
      _beatController.stop();
      _fluidController.stop();
    }
  }

  void _handleOptimisticPlayPause() {
    final nextState = !isPlaying;

    // 1. МИТТЄВО перемикаємо стан в інтерфейсі (кнопка, хвиля, обертання)
    setState(() {
      isPlaying = nextState;
      _updateAnimations(nextState);
    });

    // 2. Запускаємо логіку плавного згасання/наростання
    widget.onPlayPause();
  }

  @override
  void dispose() {
    _playbackSub?.cancel();
    _mediaItemSub?.cancel();
    _rotationController.dispose();
    _morphController.dispose();
    _beatController.dispose();
    _fluidController.dispose();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(d.inMinutes.remainder(60));
    final seconds = twoDigits(d.inSeconds.remainder(60));
    return "$minutes:$seconds";
  }

  Widget _buildArtworkWidget(String? artworkPath, double size, Color accent, Color surfaceColor) {
    if (artworkPath == null || artworkPath.isEmpty) {
      return Container(
        color: surfaceColor,
        child: Icon(Icons.music_note_rounded, size: size * 0.4, color: accent),
      );
    }

    if (artworkPath.startsWith('http')) {
      return Image.network(
        artworkPath,
        fit: BoxFit.cover,
        errorBuilder: (ctx, err, stack) => Container(
          color: surfaceColor,
          child: Icon(Icons.music_note_rounded, size: size * 0.4, color: accent),
        ),
      );
    }

    return Image.file(
      File(artworkPath),
      fit: BoxFit.cover,
      errorBuilder: (ctx, err, stack) => Container(
        color: surfaceColor,
        child: Icon(Icons.music_note_rounded, size: size * 0.4, color: accent),
      ),
    );
  }

  void _showEditMetadataDialog(BuildContext context, Song currentSong) {
    final titleController = TextEditingController(text: currentSong.title);
    final artistController = TextEditingController(
      text: (currentSong.artist == 'Локальний файл' || currentSong.artist == 'Невідомий виконавець')
          ? ''
          : currentSong.artist,
    );
    final settings = SettingsController.instance;

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: settings.surfaceColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(
            'Редагувати трек',
            style: TextStyle(
              fontFamily: 'sans-serif-rounded',
              fontWeight: FontWeight.w800,
              color: settings.textColor,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                style: TextStyle(color: settings.textColor, fontFamily: 'sans-serif-rounded'),
                decoration: InputDecoration(
                  labelText: 'Назва пісні',
                  labelStyle: TextStyle(color: settings.subTextColor),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: settings.subTextColor.withOpacity(0.4)),
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: settings.accentColor, width: 2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: artistController,
                style: TextStyle(color: settings.textColor, fontFamily: 'sans-serif-rounded'),
                decoration: InputDecoration(
                  labelText: 'Виконавець',
                  labelStyle: TextStyle(color: settings.subTextColor),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: settings.subTextColor.withOpacity(0.4)),
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: settings.accentColor, width: 2),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(
                'Скасувати',
                style: TextStyle(color: settings.subTextColor, fontFamily: 'sans-serif-rounded'),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: settings.accentColor,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () {
                final newTitle = titleController.text.trim();
                final newArtist = artistController.text.trim();

                if (newTitle.isNotEmpty) {
                  final updatedSong = Song(
                    title: newTitle,
                    artist: newArtist.isNotEmpty ? newArtist : 'Невідомий виконавець',
                    path: currentSong.path,
                    artworkUrl: currentSong.artworkUrl,
                    isOnline: currentSong.isOnline,
                  );

                  widget.songNotifier.value = null;
                  widget.songNotifier.value = updatedSong;
                }
                Navigator.pop(ctx);
              },
              child: const Text(
                'Зберегти',
                style: TextStyle(
                  color: Colors.black,
                  fontFamily: 'sans-serif-rounded',
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsController.instance;
    final accent = settings.accentColor;

    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) {
        return ValueListenableBuilder<Song?>(
          valueListenable: widget.songNotifier,
          builder: (context, currentSong, child) {
            if (currentSong == null) {
              return Scaffold(
                backgroundColor: settings.backgroundColor,
                body: Center(
                  child: Text(
                    'Немає активного треку',
                    style: TextStyle(
                      fontFamily: 'sans-serif-rounded',
                      fontWeight: FontWeight.bold,
                      color: settings.textColor,
                    ),
                  ),
                ),
              );
            }

            final displayArtist = (currentSong.artist.isEmpty || currentSong.artist == 'Локальний файл')
                ? 'Невідомий виконавець'
                : currentSong.artist;

            return Scaffold(
              backgroundColor: settings.backgroundColor,
              body: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onVerticalDragEnd: (details) {
                  if (details.primaryVelocity != null && details.primaryVelocity! > 350) {
                    Navigator.pop(context);
                  }
                },
                child: Stack(
                  children: [
                    // Повноекранний живий фон лава-лампи
                    Positioned.fill(
                      child: RepaintBoundary(
                        child: AnimatedBuilder(
                          animation: Listenable.merge([_beatController, _fluidController, _morphController]),
                          builder: (context, _) {
                            final smoothBeat = Curves.easeInOutSine.transform(_beatController.value);

                            return CustomPaint(
                              painter: _FullscreenLavalampBackgroundPainter(
                                baseBackgroundColor: settings.backgroundColor,
                                accentColor: accent,
                                beatProgress: smoothBeat,
                                fluidProgress: _fluidController.value,
                                activeProgress: _morphController.value,
                              ),
                            );
                          },
                        ),
                      ),
                    ),

                    // Інтерфейс плеєра
                    SafeArea(
                      child: Column(
                        children: [
                          // 1. Верхня панель зі стрілкою назад
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                IconButton(
                                  icon: Icon(Icons.keyboard_arrow_down_rounded, size: 36, color: settings.textColor.withOpacity(0.75)),
                                  onPressed: () => Navigator.pop(context),
                                ),
                                if (currentSong.isOnline)
                                  IconButton(
                                    icon: Icon(Icons.download_rounded, size: 28, color: accent),
                                    onPressed: widget.onDownloadCurrent,
                                  )
                                else
                                  const SizedBox(width: 48),
                              ],
                            ),
                          ),

                          // 2. Обкладинка з ефектом світіння
                          Expanded(
                            child: Center(
                              child: LayoutBuilder(
                                builder: (context, boxConstraints) {
                                  final imgSize = (boxConstraints.maxHeight * 0.88).clamp(180.0, 260.0);
                                  final glowBoxSize = imgSize * 1.95;

                                  return SizedBox(
                                    width: glowBoxSize,
                                    height: glowBoxSize,
                                    child: Stack(
                                      alignment: Alignment.center,
                                      clipBehavior: Clip.none,
                                      children: [
                                        RepaintBoundary(
                                          child: AnimatedBuilder(
                                            animation: Listenable.merge([_beatController, _fluidController, _morphController]),
                                            builder: (context, _) {
                                              final smoothBeat = Curves.easeInOutSine.transform(_beatController.value);

                                              return CustomPaint(
                                                size: Size(glowBoxSize, glowBoxSize),
                                                painter: _LavalampGlowPainter(
                                                  accentColor: accent,
                                                  beatProgress: smoothBeat,
                                                  fluidProgress: _fluidController.value,
                                                  activeProgress: _morphController.value,
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                        AnimatedSwitcher(
                                          duration: const Duration(milliseconds: 380),
                                          switchInCurve: Curves.easeOutCubic,
                                          switchOutCurve: Curves.easeInCubic,
                                          transitionBuilder: (child, animation) {
                                            return FadeTransition(
                                              opacity: animation,
                                              child: ScaleTransition(
                                                scale: Tween<double>(begin: 0.92, end: 1.0).animate(animation),
                                                child: child,
                                              ),
                                            );
                                          },
                                          child: Container(
                                            key: ValueKey<String>('cover_${currentSong.title}_${currentSong.artist}'),
                                            width: imgSize,
                                            height: imgSize,
                                            decoration: BoxDecoration(
                                              borderRadius: BorderRadius.circular(24),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: Colors.black.withOpacity(0.65),
                                                  blurRadius: 26,
                                                  offset: const Offset(0, 12),
                                                ),
                                              ],
                                            ),
                                            child: ClipRRect(
                                              borderRadius: BorderRadius.circular(24),
                                              child: _buildArtworkWidget(
                                                currentSong.artworkUrl,
                                                imgSize,
                                                accent,
                                                settings.surfaceColor,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),

                          // 3. Назва треку та виконавець
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 28.0, vertical: 8.0),
                            child: GestureDetector(
                              onLongPress: () => _showEditMetadataDialog(context, currentSong),
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 320),
                                switchInCurve: Curves.easeOutCubic,
                                switchOutCurve: Curves.easeInCubic,
                                transitionBuilder: (child, animation) {
                                  return FadeTransition(
                                    opacity: animation,
                                    child: SlideTransition(
                                      position: Tween<Offset>(
                                        begin: const Offset(0.0, 0.18),
                                        end: Offset.zero,
                                      ).animate(animation),
                                      child: child,
                                    ),
                                  );
                                },
                                child: Column(
                                  key: ValueKey<String>('info_${currentSong.title}_$displayArtist'),
                                  mainAxisSize: dynamicTextKey(currentSong),
                                  children: [
                                    Text(
                                      currentSong.title,
                                      style: TextStyle(
                                        fontFamily: 'sans-serif-rounded',
                                        fontSize: 24,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: -0.2,
                                        color: settings.textColor,
                                      ),
                                      textAlign: TextAlign.center,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      displayArtist,
                                      style: TextStyle(
                                        fontFamily: 'sans-serif-rounded',
                                        fontSize: 15,
                                        color: settings.subTextColor,
                                        fontWeight: FontWeight.w700,
                                      ),
                                      textAlign: TextAlign.center,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),

                          // 4. Панель кнопок: Shuffle та Repeat
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 28.0, vertical: 6.0),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Material(
                                  color: isShuffleActive
                                      ? accent.withOpacity(0.25)
                                      : settings.surfaceColor.withOpacity(0.6),
                                  borderRadius: BorderRadius.circular(24),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(24),
                                    onTap: () {
                                      setState(() {
                                        isShuffleActive = !isShuffleActive;
                                      });
                                      widget.onToggleShuffle();
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
                                      child: Icon(
                                        Icons.shuffle_rounded,
                                        size: 22,
                                        color: isShuffleActive ? accent : settings.textColor.withOpacity(0.55),
                                      ),
                                    ),
                                  ),
                                ),
                                Material(
                                  color: isRepeatActive
                                      ? accent.withOpacity(0.25)
                                      : settings.surfaceColor.withOpacity(0.6),
                                  borderRadius: BorderRadius.circular(24),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(24),
                                    onTap: () {
                                      setState(() {
                                        isRepeatActive = !isRepeatActive;
                                      });
                                      widget.onToggleRepeat();
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
                                      child: Icon(
                                        Icons.repeat_rounded,
                                        size: 22,
                                        color: isRepeatActive ? accent : settings.textColor.withOpacity(0.55),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          // 5. Блок хвилі з кнопками керування
                          SizedBox(
                            height: 220,
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                return Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    AnimatedBuilder(
                                      animation: _morphController,
                                      builder: (context, _) {
                                        final lineProgress = CurvedAnimation(
                                          parent: _morphController,
                                          curve: Curves.easeInOutCubic,
                                        ).value;

                                        return OverflowBox(
                                          maxWidth: constraints.maxWidth + 48,
                                          minWidth: constraints.maxWidth + 48,
                                          child: CenteredWaveformScroller(
                                            duration: duration,
                                            position: position,
                                            isPlaying: isPlaying,
                                            lineGrowProgress: lineProgress,
                                            activeColor: accent,
                                            inactiveColor: settings.subTextColor.withOpacity(0.20),
                                            onSeek: (newPos) async {
                                              await widget.audioHandler.seek(newPos);
                                            },
                                          ),
                                        );
                                      },
                                    ),

                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                                      child: Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                        crossAxisAlignment: CrossAxisAlignment.center,
                                        children: [
                                          IconButton(
                                            iconSize: 48,
                                            icon: Icon(Icons.skip_previous_rounded, color: settings.textColor),
                                            onPressed: widget.onPrev,
                                          ),
                                          GestureDetector(
                                            onTap: _handleOptimisticPlayPause,
                                            child: SizedBox(
                                              width: 96,
                                              height: 96,
                                              child: Stack(
                                                alignment: Alignment.center,
                                                children: [
                                                  AnimatedBuilder(
                                                    animation: Listenable.merge([_rotationController, _morphController]),
                                                    builder: (context, child) {
                                                      final curvedMorph = CurvedAnimation(
                                                        parent: _morphController,
                                                        curve: Curves.easeInOutCubic,
                                                      ).value;

                                                      return Transform.rotate(
                                                        angle: _rotationController.value * 2 * math.pi,
                                                        child: CustomPaint(
                                                          size: const Size(96, 96),
                                                          painter: _ScallopButtonPainter(
                                                            morphProgress: curvedMorph,
                                                            color: accent,
                                                            shadowColor: accent.withOpacity(0.55),
                                                          ),
                                                        ),
                                                      );
                                                    },
                                                  ),
                                                  AnimatedSwitcher(
                                                    duration: const Duration(milliseconds: 280),
                                                    switchInCurve: Curves.easeOutBack,
                                                    switchOutCurve: Curves.easeInBack,
                                                    transitionBuilder: (child, animation) {
                                                      return ScaleTransition(
                                                        scale: animation,
                                                        child: FadeTransition(opacity: animation, child: child),
                                                      );
                                                    },
                                                    child: Icon(
                                                      isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                                      key: ValueKey<bool>(isPlaying),
                                                      size: 48,
                                                      color: Colors.black,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                          IconButton(
                                            iconSize: 48,
                                            icon: Icon(Icons.skip_next_rounded, color: settings.textColor),
                                            onPressed: widget.onNext,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),

                          // 6. Таймінги треку
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  _formatDuration(position),
                                  style: TextStyle(
                                    fontFamily: 'sans-serif-rounded',
                                    color: settings.subTextColor,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w800,
                                    fontFeatures: const [FontFeature.tabularFigures()],
                                  ),
                                ),
                                Text(
                                  _formatDuration(duration),
                                  style: TextStyle(
                                    fontFamily: 'sans-serif-rounded',
                                    color: settings.subTextColor,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w800,
                                    fontFeatures: const [FontFeature.tabularFigures()],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  MainAxisSize dynamicTextKey(Song currentSong) => MainAxisSize.min;
}

class _FullscreenLavalampBackgroundPainter extends CustomPainter {
  final Color baseBackgroundColor;
  final Color accentColor;
  final double beatProgress;
  final double fluidProgress;
  final double activeProgress;

  _FullscreenLavalampBackgroundPainter({
    required this.baseBackgroundColor,
    required this.accentColor,
    required this.beatProgress,
    required this.fluidProgress,
    required this.activeProgress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    final bgPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          baseBackgroundColor,
          baseBackgroundColor.withOpacity(0.96),
          baseBackgroundColor,
        ],
      ).createShader(rect);
    canvas.drawRect(rect, bgPaint);

    final hsl = HSLColor.fromColor(accentColor);
    final secondary = hsl.withHue((hsl.hue + 32.0) % 360.0).toColor();

    final t = fluidProgress * 2 * math.pi;
    final beatMul = 1.0 + (0.12 * beatProgress * activeProgress);

    final topCenter = Offset(
      size.width * 0.5 + math.sin(t) * (size.width * 0.22),
      size.height * 0.18 + math.cos(t * 0.8) * 35.0,
    );
    final topPaint = Paint()
      ..color = accentColor.withOpacity(0.15 + 0.08 * activeProgress + 0.04 * beatProgress)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 110.0);
    canvas.drawOval(
      Rect.fromCenter(
        center: topCenter,
        width: size.width * 1.1 * beatMul,
        height: size.height * 0.42 * beatMul,
      ),
      topPaint,
    );

    if (activeProgress > 0.02) {
      final midCenter = Offset(
        size.width * 0.5 - math.cos(t * 1.1) * (size.width * 0.25),
        size.height * 0.65 + math.sin(t) * 45.0,
      );
      final midPaint = Paint()
        ..color = secondary.withOpacity((0.12 + 0.06 * beatProgress) * activeProgress)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 125.0);
      canvas.drawOval(
        Rect.fromCenter(
          center: midCenter,
          width: size.width * 1.15 * beatMul,
          height: size.height * 0.48 * beatMul,
        ),
        midPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FullscreenLavalampBackgroundPainter oldDelegate) {
    return oldDelegate.beatProgress != beatProgress ||
        oldDelegate.fluidProgress != fluidProgress ||
        oldDelegate.activeProgress != activeProgress ||
        oldDelegate.accentColor != accentColor ||
        oldDelegate.baseBackgroundColor != baseBackgroundColor;
  }
}

class _LavalampGlowPainter extends CustomPainter {
  final Color accentColor;
  final double beatProgress;
  final double fluidProgress;
  final double activeProgress;

  _LavalampGlowPainter({
    required this.accentColor,
    required this.beatProgress,
    required this.fluidProgress,
    required this.activeProgress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    if (activeProgress <= 0.05) {
      final paint = Paint()
        ..color = accentColor.withOpacity(0.24)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 54.0);
      canvas.drawCircle(center, size.width * 0.32, paint);
      return;
    }

    final hsl = HSLColor.fromColor(accentColor);
    final secondaryColor = hsl
        .withHue((hsl.hue + 28.0) % 360.0)
        .withLightness((hsl.lightness * 1.1).clamp(0.0, 1.0))
        .toColor();

    final tertiaryColor = hsl
        .withHue((hsl.hue - 26.0 + 360.0) % 360.0)
        .toColor();

    final t = fluidProgress * 2 * math.pi;
    final beatScale = 1.0 + (0.22 * beatProgress * activeProgress);

    final baseRadius = (size.width * 0.38) * beatScale;
    final basePaint = Paint()
      ..color = accentColor.withOpacity((0.36 + 0.16 * beatProgress) * activeProgress)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 72.0);
    canvas.drawCircle(center, baseRadius, basePaint);

    final offset1 = Offset(
      center.dx + math.cos(t) * 44.0,
      center.dy + math.sin(t * 1.25) * 36.0,
    );
    final blob1Paint = Paint()
      ..color = secondaryColor.withOpacity((0.42 + 0.12 * math.sin(t)) * activeProgress)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 65.0);
    canvas.drawOval(
      Rect.fromCenter(
        center: offset1,
        width: (size.width * 0.70 + 26.0 * math.cos(t * 2)) * beatScale,
        height: (size.height * 0.58 + 30.0 * math.sin(t)) * beatScale,
      ),
      blob1Paint,
    );

    final offset2 = Offset(
      center.dx + math.sin(t * 0.95) * -46.0,
      center.dy + math.cos(t * 1.15) * -38.0,
    );
    final blob2Paint = Paint()
      ..color = tertiaryColor.withOpacity((0.38 + 0.10 * math.cos(t * 1.4)) * activeProgress)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 68.0);
    canvas.drawOval(
      Rect.fromCenter(
        center: offset2,
        width: (size.width * 0.62 + 24.0 * math.sin(t)) * beatScale,
        height: (size.height * 0.68 + 26.0 * math.cos(t * 0.8)) * beatScale,
      ),
      blob2Paint,
    );
  }

  @override
  bool shouldRepaint(covariant _LavalampGlowPainter oldDelegate) {
    return oldDelegate.beatProgress != beatProgress ||
        oldDelegate.fluidProgress != fluidProgress ||
        oldDelegate.activeProgress != activeProgress ||
        oldDelegate.accentColor != accentColor;
  }
}

class _ScallopButtonPainter extends CustomPainter {
  final double morphProgress;
  final Color color;
  final Color shadowColor;

  _ScallopButtonPainter({
    required this.morphProgress,
    required this.color,
    required this.shadowColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final baseRadius = (size.width / 2) - 9.0;

    final shadowPaint = Paint()
      ..color = shadowColor
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18.0);

    final fillPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final path = Path();
    const int petals = 12;
    final double maxAmplitude = 5.2 * morphProgress;
    const int steps = petals * 16;

    for (int i = 0; i <= steps; i++) {
      final double theta = (i / steps) * 2 * math.pi;
      final waveOut = (1.0 + math.cos(petals * theta)) / 2.0;
      final double r = baseRadius + maxAmplitude * waveOut;

      final double x = center.dx + r * math.cos(theta);
      final double y = center.dy + r * math.sin(theta);

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();

    canvas.drawPath(path, shadowPaint);
    canvas.drawPath(path, fillPaint);
  }

  @override
  bool shouldRepaint(covariant _ScallopButtonPainter oldDelegate) {
    return oldDelegate.morphProgress != morphProgress ||
        oldDelegate.color != color ||
        oldDelegate.shadowColor != shadowColor;
  }
}

class CenteredWaveformScroller extends StatefulWidget {
  final Duration duration;
  final Duration position;
  final bool isPlaying;
  final double lineGrowProgress;
  final Color activeColor;
  final Color inactiveColor;
  final ValueChanged<Duration> onSeek;

  const CenteredWaveformScroller({
    super.key,
    required this.duration,
    required this.position,
    required this.isPlaying,
    required this.lineGrowProgress,
    required this.activeColor,
    required this.inactiveColor,
    required this.onSeek,
  });

  @override
  State<CenteredWaveformScroller> createState() => _CenteredWaveformScrollerState();
}

class _CenteredWaveformScrollerState extends State<CenteredWaveformScroller>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ticker;
  double _smoothPositionMs = 0.0;
  DateTime _lastTickTime = DateTime.now();

  @override
  void initState() {
    super.initState();
    _smoothPositionMs = widget.position.inMilliseconds.toDouble();
    _lastTickTime = DateTime.now();

    _ticker = AnimationController.unbounded(vsync: this)..addListener(_onTick);

    if (widget.isPlaying) {
      _ticker.repeat(min: 0, max: 1, period: const Duration(seconds: 1));
    }
  }

  void _onTick() {
    final now = DateTime.now();
    final elapsedMs = now.difference(_lastTickTime).inMicroseconds / 1000.0;
    _lastTickTime = now;

    if (widget.isPlaying && widget.duration.inMilliseconds > 0) {
      setState(() {
        _smoothPositionMs += elapsedMs;
        if (_smoothPositionMs > widget.duration.inMilliseconds) {
          _smoothPositionMs = widget.duration.inMilliseconds.toDouble();
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant CenteredWaveformScroller oldWidget) {
    super.didUpdateWidget(oldWidget);

    final realMs = widget.position.inMilliseconds.toDouble();
    if ((_smoothPositionMs - realMs).abs() > 250 || !widget.isPlaying) {
      _smoothPositionMs = realMs;
    }

    if (widget.isPlaying != oldWidget.isPlaying) {
      _lastTickTime = DateTime.now();
      if (widget.isPlaying) {
        if (!_ticker.isAnimating) {
          _ticker.repeat(min: 0, max: 1, period: const Duration(seconds: 1));
        }
      } else {
        _ticker.stop();
      }
    }
  }

  @override
  void dispose() {
    _ticker.removeListener(_onTick);
    _ticker.dispose();
    super.dispose();
  }

  void _handleDrag(DragUpdateDetails details, double totalWidth) {
    if (widget.duration.inMilliseconds <= 0 || totalWidth <= 0) return;
    final double deltaMs =
        (-details.delta.dx / (totalWidth * 0.9)) * widget.duration.inMilliseconds;
    final double newMs = (_smoothPositionMs + deltaMs)
        .clamp(0.0, widget.duration.inMilliseconds.toDouble());
    setState(() => _smoothPositionMs = newMs);
    widget.onSeek(Duration(milliseconds: newMs.toInt()));
  }

  void _handleTap(TapDownDetails details, double totalWidth) {
    if (widget.duration.inMilliseconds <= 0 || totalWidth <= 0) return;
    final double center = totalWidth / 2;
    final double offsetFromCenter = details.localPosition.dx - center;
    final double deltaMs =
        (offsetFromCenter / (totalWidth * 0.9)) * widget.duration.inMilliseconds;
    final double newMs = (_smoothPositionMs + deltaMs)
        .clamp(0.0, widget.duration.inMilliseconds.toDouble());
    setState(() => _smoothPositionMs = newMs);
    widget.onSeek(Duration(milliseconds: newMs.toInt()));
  }

  @override
  Widget build(BuildContext context) {
    final progress = widget.duration.inMilliseconds > 0
        ? (_smoothPositionMs / widget.duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    const double maxLineHeight = 230.0;
    final double currentLineHeight = maxLineHeight * widget.lineGrowProgress;

    final hsl = HSLColor.fromColor(widget.activeColor);
    final edgeSoftColor = hsl
        .withLightness((hsl.lightness * 0.80).clamp(0.0, 1.0))
        .toColor()
        .withOpacity(0.85 * widget.lineGrowProgress);

    final centerBrightColor = widget.activeColor.withOpacity(0.95 * widget.lineGrowProgress);

    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _handleTap(d, constraints.maxWidth),
          onHorizontalDragUpdate: (d) => _handleDrag(d, constraints.maxWidth),
          child: SizedBox(
            height: maxLineHeight,
            width: constraints.maxWidth,
            child: Stack(
              alignment: Alignment.center,
              children: [
                RepaintBoundary(
                  child: CustomPaint(
                    size: Size(constraints.maxWidth, 220),
                    painter: _InfiniteCenteredWaveformPainter(
                      progress: progress,
                      activeColor: widget.activeColor.withOpacity(0.38),
                      inactiveColor: widget.inactiveColor,
                    ),
                  ),
                ),
                if (currentLineHeight > 4.0)
                  IgnorePointer(
                    child: Container(
                      width: 12.0,
                      height: currentLineHeight,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6.0),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            edgeSoftColor,
                            centerBrightColor,
                            centerBrightColor,
                            edgeSoftColor,
                          ],
                          stops: const [0.0, 0.28, 0.72, 1.0],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: widget.activeColor.withOpacity(0.60 * widget.lineGrowProgress),
                            blurRadius: 16,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _InfiniteCenteredWaveformPainter extends CustomPainter {
  final double progress;
  final Color activeColor;
  final Color inactiveColor;

  _InfiniteCenteredWaveformPainter({
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const int totalBands = 80;
    const double barWidth = 10.5;
    const double barSpacing = 6.5;
    const double unitStep = barWidth + barSpacing;

    final double centerX = size.width / 2;
    final double scrollOffset = progress * (totalBands * unitStep);

    final activePaint = Paint()
      ..color = activeColor
      ..style = PaintingStyle.fill;

    final inactivePaint = Paint()
      ..color = inactiveColor
      ..style = PaintingStyle.fill;

    final double currentBandAtCenter = progress * totalBands;

    for (int i = 0; i < totalBands; i++) {
      final double x = centerX + (i * unitStep - scrollOffset);

      if (x < -unitStep || x > size.width + unitStep) continue;

      final double normalizedHeight = (0.24 +
              0.54 * math.sin(i * 0.38).abs() +
              0.22 * math.cos(i * 0.82).abs())
          .clamp(0.20, 1.0);

      final double currentBarHeight = size.height * normalizedHeight;
      final double y = (size.height - currentBarHeight) / 2;

      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x - (barWidth / 2), y, barWidth, currentBarHeight),
        const Radius.circular(5.5),
      );

      final bool isPassed = i < currentBandAtCenter;
      canvas.drawRRect(rect, isPassed ? activePaint : inactivePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _InfiniteCenteredWaveformPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.inactiveColor != inactiveColor;
  }
}