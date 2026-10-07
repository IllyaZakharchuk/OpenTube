package com.example.opentube

import android.content.Context
import android.net.Uri
import androidx.media3.common.MediaItem
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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app/dsp")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "load" -> {
                        val path = call.argument<String>("path")
                        if (path != null) {
                            player.setMediaItem(MediaItem.fromUri(Uri.parse(path)))
                            player.prepare()
                            result.success(null)
                        } else {
                            result.error("ARG_ERROR", "Path is null", null)
                        }
                    }
                    "play" -> {
                        player.play()
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
        player.release()
        super.onDestroy()
    }
}