package com.example.opentube

import android.content.Context
import android.content.Intent
import android.media.audiofx.AudioEffect
import android.media.audiofx.Virtualizer
import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink
import com.example.opentube.dsp.DspConfig
import com.example.opentube.dsp.DspProcessor
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {

    private val dsp = DspProcessor()
    private lateinit var player: ExoPlayer
    private var virtualizer: Virtualizer? = null
    private var lastSessionId: Int = 0

    private fun openAudioSession(sessionId: Int) {
        if (sessionId <= 0 || sessionId == AudioEffect.ERROR_BAD_VALUE) return
        if (sessionId == lastSessionId) return
        lastSessionId = sessionId

        val intent = Intent(AudioEffect.ACTION_OPEN_AUDIO_EFFECT_CONTROL_SESSION).apply {
            putExtra(AudioEffect.EXTRA_AUDIO_SESSION, sessionId)
            putExtra(AudioEffect.EXTRA_PACKAGE_NAME, packageName)
            putExtra(AudioEffect.EXTRA_CONTENT_TYPE, AudioEffect.CONTENT_TYPE_MUSIC)
        }
        sendBroadcast(intent)
    }

    private fun closeAudioSession(sessionId: Int) {
        if (sessionId <= 0 || sessionId == AudioEffect.ERROR_BAD_VALUE) return

        val intent = Intent(AudioEffect.ACTION_CLOSE_AUDIO_EFFECT_CONTROL_SESSION).apply {
            putExtra(AudioEffect.EXTRA_AUDIO_SESSION, sessionId)
            putExtra(AudioEffect.EXTRA_PACKAGE_NAME, packageName)
        }
        sendBroadcast(intent)
        lastSessionId = 0
    }

    private fun setupAudioEffects(sessionId: Int) {
        if (sessionId <= 0 || sessionId == AudioEffect.ERROR_BAD_VALUE) return
        try {
            virtualizer?.release()
            virtualizer = Virtualizer(0, sessionId).apply {
                enabled = true
                if (strengthSupported) {
                    setStrength(500.toShort())
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val renderers = object : DefaultRenderersFactory(this) {
            override fun buildAudioSink(
                context: Context,
                enableFloatOutput: Boolean,
                enableAudioTrackPlaybackParams: Boolean,
            ): AudioSink = DefaultAudioSink.Builder(context)
                .setAudioProcessors(arrayOf<AudioProcessor>(dsp))
                .setEnableFloatOutput(false)
                .build()
        }
        player = ExoPlayer.Builder(this, renderers).build()

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app/dsp")

        player.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                if (playbackState == Player.STATE_READY) {
                    val sId = player.audioSessionId
                    setupAudioEffects(sId)
                    openAudioSession(sId)
                } else if (playbackState == Player.STATE_ENDED) {
                    channel.invokeMethod("onTrackEnded", null)
                }
            }
        })

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "load" -> {
                    val path = call.argument<String>("path")
                    if (path != null) {
                        player.stop()
                        player.clearMediaItems()
                        player.setMediaItem(MediaItem.fromUri(Uri.parse(path)))
                        player.prepare()
                        result.success(null)
                    } else {
                        result.error("ARG_ERROR", "Path is null", null)
                    }
                }
                "play" -> {
                    player.play()
                    val sId = player.audioSessionId
                    setupAudioEffects(sId)
                    openAudioSession(sId)
                    result.success(null)
                }
                "pause" -> {
                    player.pause()
                    result.success(null)
                }
                "seekTo" -> {
                    val ms = (call.argument<Number>("ms") ?: 0).toLong()
                    player.seekTo(ms)
                    result.success(null)
                }
                "position" -> {
                    result.success(player.currentPosition)
                }
                "duration" -> {
                    val dur = player.duration
                    if (dur != C.TIME_UNSET && dur > 0) {
                        result.success(dur)
                    } else {
                        result.success(0L)
                    }
                }
                "setConfig" -> {
                    @Suppress("UNCHECKED_CAST")
                    val map = call.arguments as? Map<String, Any?>
                    if (map != null) {
                        dsp.config = DspConfig.fromMap(map)
                        result.success(null)
                    } else {
                        result.error("ARG_ERROR", "Config map is null", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        closeAudioSession(player.audioSessionId)
        virtualizer?.release()
        player.release()
        super.onDestroy()
    }
}