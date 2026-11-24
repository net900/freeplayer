package cn.freeplayer.app.bvc2

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.Surface
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.extractor.DefaultExtractorsFactory
import androidx.media3.extractor.ExtractorsFactory
import androidx.media3.extractor.mp4.Bvc2Mp4Extractor
import androidx.media3.extractor.mp4.Mp4Extractor
import cn.freeplayer.app.cenc.CencDataSource
import cn.freeplayer.app.cenc.CencKeyStore
import io.flutter.view.TextureRegistry

/**
 * One ExoPlayer instance for ByteVC2 episodes. The vendor decoder renders
 * frames into a Flutter-owned SurfaceTexture, so the existing Flutter player
 * UI keeps working over a normal Texture.
 */
class Bvc2Player(
    context: Context,
    private val textures: TextureRegistry,
    private val emit: (Map<String, Any?>) -> Unit,
) {
    private val appContext = context.applicationContext
    private var player: ExoPlayer? = null
    private var surface: Surface? = null
    private var texture: TextureRegistry.SurfaceTextureEntry? = null
    // Flutter's first texture id is 0; -1 means "not created yet".
    private var textureIdValue = -1L
    private val handler = Handler(Looper.getMainLooper())
    private var videoWidth = 0
    private var videoHeight = 0
    private var error: String? = null
    private val ticker = object : Runnable {
        override fun run() {
            emitState()
            handler.postDelayed(this, 250)
        }
    }

    val textureId: Long
        get() = textureIdValue

    fun isAvailable(): Boolean = Bvc2Native.isAvailable()

    fun version(): String = Bvc2Native.getVersion()

    fun open(
        url: String,
        autoPlay: Boolean,
        startPositionMs: Long,
        keyHex: String = "",
        userAgent: String = "",
    ): Long {
        val exo = ensurePlayer()
        exo.stop()
        exo.clearMediaItems()
        // The key travels with the URI: the DataSource decrypts in-process,
        // so there is no loopback proxy in between.
        CencKeyStore.put(url, keyHex, userAgent)
        error = null
        exo.setMediaItem(MediaItem.fromUri(url))
        exo.prepare()
        if (startPositionMs > 0) exo.seekTo(startPositionMs)
        exo.playWhenReady = autoPlay
        emitState()
        return textureId
    }

    private fun ensurePlayer(): ExoPlayer {
        player?.let { return it }
        // The decoder writes RGBA into the surface with ANativeWindow_lock;
        // SurfaceProducer's ImageReader uses a PRIVATE format on API 29+, so
        // the plain SurfaceTexture path is the one that accepts CPU buffers.
        val entry = textures.createSurfaceTexture()
        texture = entry
        surface = Surface(entry.surfaceTexture())
        textureIdValue = entry.id()
        android.util.Log.d(
            "FreePlayerBvc2",
            "surfaceTexture id=$textureIdValue",
        )
        val extractors = ExtractorsFactory {
            DefaultExtractorsFactory().createExtractors().map { extractor ->
                if (extractor is Mp4Extractor && Bvc2Native.isAvailable()) {
                    Bvc2Mp4Extractor()
                } else {
                    extractor
                }
            }.toTypedArray()
        }
        val exo = ExoPlayer.Builder(appContext, Bvc2RenderersFactory(appContext))
            // The stream is a decrypted localhost proxy, so waiting for the
            // default 2.5 s of media before the first frame only adds latency
            // to every episode switch.
            .setLoadControl(
                DefaultLoadControl.Builder()
                    .setBufferDurationsMs(
                        /* minBufferMs = */ 2_000,
                        /* maxBufferMs = */ 15_000,
                        /* bufferForPlaybackMs = */ 300,
                        /* bufferForPlaybackAfterRebufferMs = */ 500,
                    )
                    .build(),
            )
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(C.USAGE_MEDIA)
                    .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                    .build(),
                true,
            )
            .setMediaSourceFactory(
                DefaultMediaSourceFactory(CencDataSource.Factory(appContext), extractors),
            )
            .build()
        exo.setVideoSurface(surface)
        exo.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                emitState()
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                emitState()
            }

            override fun onVideoSizeChanged(videoSize: VideoSize) {
                videoWidth = videoSize.width
                videoHeight = videoSize.height
                android.util.Log.d(
                    "FreePlayerBvc2",
                    "videoSize ${videoSize.width}x${videoSize.height} texture=$textureId",
                )
                emitState()
            }

            override fun onPlayerError(playerError: PlaybackException) {
                error = playerError.message ?: playerError.errorCodeName
                emitState()
            }
        })
        player = exo
        handler.post(ticker)
        emit(mapOf("textureId" to textureId))
        return exo
    }

    fun play() {
        player?.play()
    }

    fun pause() {
        player?.pause()
    }

    fun seekTo(positionMs: Long) {
        player?.seekTo(positionMs)
    }

    fun setVolume(volume: Float) {
        player?.volume = volume.coerceIn(0f, 1f)
    }

    fun setRate(rate: Float) {
        player?.playbackParameters = PlaybackParameters(rate)
    }

    fun release() {
        player?.stop()
        player?.clearMediaItems()
        emitState()
    }

    fun dispose() {
        handler.removeCallbacksAndMessages(null)
        player?.release()
        player = null
        surface?.release()
        surface = null
        texture?.release()
        texture = null
        textureIdValue = -1L
        videoWidth = 0
        videoHeight = 0
        error = null
    }

    private fun emitState() {
        val exo = player ?: return
        val duration = exo.duration
        emit(
            mapOf(
                "textureId" to textureId,
                "playing" to exo.isPlaying,
                "positionMs" to exo.currentPosition,
                "durationMs" to if (duration == C.TIME_UNSET) 0L else duration,
                "bufferedMs" to exo.bufferedPosition,
                "width" to videoWidth,
                "height" to videoHeight,
                "buffering" to (exo.playbackState == Player.STATE_BUFFERING),
                "ready" to (exo.playbackState == Player.STATE_READY ||
                    exo.playbackState == Player.STATE_ENDED),
                "completed" to (exo.playbackState == Player.STATE_ENDED),
                "error" to error,
            ),
        )
    }
}
