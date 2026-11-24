package cn.freeplayer.app.cenc

import android.content.Context
import android.net.Uri
import android.util.Log
import androidx.media3.common.C
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultDataSource
import java.io.IOException

/**
 * ExoPlayer DataSource that decrypts CENC samples in-process.
 *
 * URIs registered in [CencKeyStore] are served as plaintext: each read window
 * is widened to sample edges, fetched as ciphertext, and decrypted with the
 * portable CENC core. Everything else (plain HTTP, local files) falls through
 * to Media3's [DefaultDataSource] unchanged.
 */
class CencDataSource(context: Context) : BaseDataSource(/* isNetwork= */ true) {
    private val appContext = context.applicationContext
    private var fallback: DataSource? = null
    private var media: CencMedia? = null
    private var uri: Uri? = null
    private var readPosition = 0L
    private var endPosition = 0L
    private var window: CencMedia.Window? = null
    private var fetched = false
    private var active = false

    override fun open(dataSpec: DataSpec): Long {
        transferInitializing(dataSpec)
        uri = dataSpec.uri
        val entry = CencKeyStore.get(dataSpec.uri.toString())
        if (entry == null) {
            val source = DefaultDataSource.Factory(appContext).createDataSource()
            fallback = source
            val length = source.open(dataSpec)
            transferStarted(dataSpec)
            active = true
            return length
        }
        val opened = CencMedia.obtain(
            dataSpec.uri.toString(),
            entry.keyHex,
            entry.userAgent,
            acquire = true,
        )
        media = opened
        Log.d(TAG, "direct open at ${dataSpec.position} size=${opened.size}")
        val total = opened.size
        readPosition = dataSpec.position
        endPosition = if (dataSpec.length == C.LENGTH_UNSET.toLong()) {
            total - 1
        } else {
            minOf(total - 1, dataSpec.position + dataSpec.length - 1)
        }
        transferStarted(dataSpec)
        active = true
        if (readPosition > endPosition) return 0
        return endPosition - readPosition + 1
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        fallback?.let { return it.read(buffer, offset, length) }
        val opened = media ?: return C.RESULT_END_OF_INPUT
        if (length == 0) return 0
        if (readPosition > endPosition) return C.RESULT_END_OF_INPUT
        var current = window
        if (current == null || readPosition < current.start ||
            readPosition >= current.start + current.bytes.size
        ) {
            val hop = if (fetched) HOP else FIRST_HOP
            val windowEnd = minOf(readPosition + hop - 1, endPosition)
            current = opened.plainWindow(readPosition, windowEnd)
            window = current
            fetched = true
        }
        val from = (readPosition - current.start).toInt()
        if (from < 0 || from >= current.bytes.size) return C.RESULT_END_OF_INPUT
        val available = (current.bytes.size - from).toLong()
        val remaining = endPosition - readPosition + 1
        val take = minOf(length.toLong(), available, remaining).toInt()
        if (take <= 0) return C.RESULT_END_OF_INPUT
        System.arraycopy(current.bytes, from, buffer, offset, take)
        readPosition += take
        bytesTransferred(take)
        return take
    }

    override fun getUri(): Uri? = uri

    override fun close() {
        val source = fallback
        fallback = null
        if (source != null) {
            try {
                source.close()
            } catch (_: IOException) {
                // The player may already have torn the source down.
            }
        }
        media?.release()
        media = null
        window = null
        uri = null
        if (active) {
            active = false
            transferEnded()
        }
    }

    class Factory(private val context: Context) : DataSource.Factory {
        override fun createDataSource(): DataSource = CencDataSource(context)
    }

    private companion object {
        const val TAG = "FreePlayerCenc"
        // Same hop sizes as the Dart proxy: a small first window gets the moov
        // parsing started quickly, larger ones keep CDN request counts low.
        const val FIRST_HOP = 256 * 1024L
        const val HOP = 2 * 1024 * 1024L
    }
}
