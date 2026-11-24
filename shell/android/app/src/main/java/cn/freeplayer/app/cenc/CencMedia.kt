package cn.freeplayer.app.cenc

import android.net.Uri
import android.util.Log
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/**
 * One encrypted stream's byte source: size probe, MP4 CENC index and
 * on-demand decrypted windows.
 *
 * This mirrors the Dart DecryptProxy (same C core, same sample-span
 * widening) but runs inside the player process, so ExoPlayer reads plaintext
 * from [CencDataSource] with no loopback HTTP hop.
 */
class CencMedia private constructor(
    val url: String,
    private val key: ByteArray,
    private val userAgent: String,
) {
    /** Plaintext bytes whose first byte is absolute offset [start]. */
    class Window(val start: Long, val bytes: ByteArray)

    var size: Long = 0
        private set

    @Volatile
    private var lastUsed = System.currentTimeMillis()

    private var index = 0L
    private var refs = 1
    private var whole: ByteArray? = null
    private var head: ByteArray? = null

    fun acquire(): CencMedia {
        synchronized(this) { refs++ }
        return this
    }

    fun release() {
        val free = synchronized(this) {
            refs--
            refs == 0
        }
        if (free) dispose()
    }

    /** Decrypts the byte range [start, end] widened to whole samples. */
    fun plainWindow(start: Long, end: Long): Window {
        lastUsed = System.currentTimeMillis()
        val handle = synchronized(this) { index }
        if (handle == 0L) throw IOException("索引已释放")
        val out = LongArray(2)
        if (CencNative.nativeIndexSpan(handle, start, end, out) != 0) {
            throw IOException("索引不可用")
        }
        val lo = out[0]
        val hi = out[1]
        val data = fetch(lo, hi)
        if (CencNative.nativeDecrypt(handle, key, data, lo) != 0) {
            throw IOException("解密失败")
        }
        return Window(lo, data)
    }

    private fun load() {
        var window = FIRST_HOP.toLong()
        var lastError = ""
        while (true) {
            val got = requestRange(0, window - 1)
            val data: ByteArray
            if (got.status == HttpURLConnection.HTTP_OK) {
                // Range was ignored: the body starts at 0 and is the file.
                val body = got.bytes
                size = body.size.toLong()
                if (size <= WHOLE_MAX) whole = body
                data = slice(body, 0, window - 1)
            } else {
                if (got.total > 0) {
                    size = got.total
                } else if (size <= 0) {
                    // A 206 without Content-Range cannot reveal the file size;
                    // fall back to a HEAD probe before guessing.
                    val probed = probeSize()
                    size = if (probed > 0) probed else got.bytes.size.toLong()
                }
                data = got.bytes
            }
            if (size <= 0) throw IOException("无法获取视频大小")
            head = data
            index = CencNative.nativeIndexCreate(data, 0, size)
            if (index != 0L) {
                Log.d(TAG, "index ready size=$size window=${data.size}")
                return
            }
            lastError = CencNative.nativeIndexError()
            if (size <= window || window >= MAX_WINDOW) break
            window = (window * 8).coerceAtMost(MAX_WINDOW.toLong())
        }
        // A moov at the end of a large file: retry with the final window.
        if (size > MAX_WINDOW) {
            val start = size - MAX_WINDOW
            val got = requestRange(start, size - 1)
            if (got.status == HttpURLConnection.HTTP_OK) {
                size = got.bytes.size.toLong()
                if (size <= WHOLE_MAX) whole = got.bytes
                index = CencNative.nativeIndexCreate(got.bytes, 0, size)
            } else {
                index = CencNative.nativeIndexCreate(got.bytes, start, size)
            }
            if (index != 0L) return
            lastError = CencNative.nativeIndexError()
        }
        throw IOException("无法解析视频索引：${lastError.ifEmpty { "未知错误" }}")
    }

    private fun evict() {
        val free = synchronized(this) {
            refs--
            refs == 0
        }
        if (free) dispose()
    }

    private fun dispose() {
        synchronized(this) {
            val handle = index
            index = 0
            whole = null
            head = null
            if (handle != 0L) CencNative.nativeIndexFree(handle)
        }
    }

    private fun fetch(start: Long, end: Long): ByteArray {
        whole?.let { return slice(it, start, end) }
        head?.let { cached ->
            if (end < cached.size) return slice(cached, start, end)
        }
        val got = requestRange(start, end)
        if (got.status == HttpURLConnection.HTTP_OK) {
            if (got.bytes.size.toLong() >= size && size <= WHOLE_MAX) {
                whole = got.bytes
            }
            val out = slice(got.bytes, start, end)
            if (out.isEmpty()) throw IOException("上游返回不完整")
            return out
        }
        if (got.bytes.size.toLong() < end - start + 1) {
            throw IOException("上游返回不完整")
        }
        return got.bytes
    }

    private class Response(val status: Int, val bytes: ByteArray, val total: Long)

    private fun requestRange(start: Long, end: Long): Response =
        requestRange(start, end, withReferer = false)

    private fun requestRange(start: Long, end: Long, withReferer: Boolean): Response {
        val connection = openConnection(start, end, withReferer)
        try {
            val status = connection.responseCode
            if (status == HttpURLConnection.HTTP_FORBIDDEN && !withReferer) {
                connection.disconnect()
                return requestRange(start, end, withReferer = true)
            }
            if (status != HttpURLConnection.HTTP_OK &&
                status != HttpURLConnection.HTTP_PARTIAL
            ) {
                throw IOException("上游返回 $status")
            }
            val bytes = connection.inputStream.use { it.readBytes() }
            val total = parseTotal(connection.getHeaderField("Content-Range"))
            return Response(status, bytes, total)
        } finally {
            connection.disconnect()
        }
    }

    private fun probeSize(): Long {
        try {
            val connection = URL(url).openConnection() as HttpURLConnection
            connection.requestMethod = "HEAD"
            connection.connectTimeout = 15_000
            connection.readTimeout = 15_000
            connection.setRequestProperty("Accept-Encoding", "identity")
            if (userAgent.isNotEmpty()) {
                connection.setRequestProperty("User-Agent", userAgent)
            }
            try {
                val length = connection.contentLengthLong
                if (length > 0) return length
            } finally {
                connection.disconnect()
            }
        } catch (_: Exception) {
            // Fall through: the caller uses the bytes it already has.
        }
        return 0
    }

    private fun openConnection(
        start: Long,
        end: Long,
        withReferer: Boolean,
    ): HttpURLConnection {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = 15_000
        connection.readTimeout = 30_000
        connection.instanceFollowRedirects = true
        connection.setRequestProperty("Range", "bytes=$start-$end")
        connection.setRequestProperty("Accept-Encoding", "identity")
        if (userAgent.isNotEmpty()) {
            connection.setRequestProperty("User-Agent", userAgent)
        }
        if (withReferer) {
            val uri = Uri.parse(url)
            connection.setRequestProperty("Referer", "${uri.scheme}://${uri.host}/")
        }
        return connection
    }

    companion object {
        private const val TAG = "FreePlayerCenc"
        private const val FIRST_HOP = 256 * 1024
        private const val MAX_WINDOW = 8 * 1024 * 1024
        private const val WHOLE_MAX = 64L * 1024 * 1024
        private const val MAX_ENTRIES = 8

        private val cache = HashMap<String, CencMedia>()

        /**
         * Prefetch hook: parses the index and caches the moov window while the
         * current episode still plays. Failures are retried on open.
         */
        fun warm(url: String, keyHex: String, userAgent: String) {
            obtain(url, keyHex, userAgent)
        }

        fun obtain(
            url: String,
            keyHex: String,
            userAgent: String,
            acquire: Boolean = false,
        ): CencMedia {
            val cacheKey = "$url|$keyHex"
            synchronized(cache) {
                cache[cacheKey]?.let {
                    it.lastUsed = System.currentTimeMillis()
                    if (acquire) it.acquire()
                    return it
                }
                val key = decodeKey(keyHex) ?: throw IOException("密钥无效")
                val media = CencMedia(url, key, userAgent)
                try {
                    media.load()
                } catch (error: Throwable) {
                    media.dispose()
                    throw error
                }
                cache[cacheKey] = media
                if (acquire) media.acquire()
                evictLocked()
                return media
            }
        }

        private fun evictLocked() {
            while (cache.size > MAX_ENTRIES) {
                val now = System.currentTimeMillis()
                var victim: Map.Entry<String, CencMedia>? = null
                for (entry in cache.entries) {
                    if (now - entry.value.lastUsed < 30_000) continue
                    val current = victim
                    if (current == null ||
                        entry.value.lastUsed < current.value.lastUsed
                    ) {
                        victim = entry
                    }
                }
                if (victim == null) {
                    for (entry in cache.entries) {
                        val current = victim
                        if (current == null ||
                            entry.value.lastUsed < current.value.lastUsed
                        ) {
                            victim = entry
                        }
                    }
                }
                val entry = victim ?: return
                cache.remove(entry.key)
                entry.value.evict()
            }
        }

        private fun decodeKey(hex: String): ByteArray? {
            val clean = hex.trim()
            if (clean.length < 32 || clean.length % 2 != 0) return null
            val out = ByteArray(clean.length / 2)
            for (i in out.indices) {
                val value = clean.substring(i * 2, i * 2 + 2).toIntOrNull(16) ?: return null
                out[i] = value.toByte()
            }
            return out
        }

        /** Never returns a view: the caller decrypts the array in place. */
        private fun slice(data: ByteArray, start: Long, end: Long): ByteArray {
            if (start < 0 || start >= data.size) return ByteArray(0)
            val stop = minOf(end + 1, data.size.toLong())
            if (stop <= start) return ByteArray(0)
            return data.copyOfRange(start.toInt(), stop.toInt())
        }

        private fun parseTotal(header: String?): Long {
            if (header == null) return 0
            val slash = header.lastIndexOf('/')
            if (slash < 0) return 0
            return header.substring(slash + 1).trim().toLongOrNull() ?: 0
        }
    }
}
