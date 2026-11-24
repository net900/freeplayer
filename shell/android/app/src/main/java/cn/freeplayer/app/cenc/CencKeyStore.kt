package cn.freeplayer.app.cenc

import android.net.Uri
import java.util.concurrent.ConcurrentHashMap

/**
 * Content keys the gateway handed out for client-decrypt streams, keyed by
 * the URI ExoPlayer will open. An empty key removes the entry, so a stream
 * that no longer needs decryption plays through the plain DataSource.
 */
object CencKeyStore {
    class Entry(val key: ByteArray, val keyHex: String, val userAgent: String)

    private val entries = ConcurrentHashMap<String, Entry>()

    fun put(url: String, keyHex: String, userAgent: String) {
        val uri = Uri.parse(url).toString()
        if (keyHex.isEmpty()) {
            entries.remove(uri)
            return
        }
        val key = decodeHex(keyHex)
        if (key == null) {
            entries.remove(uri)
            return
        }
        if (entries.size > 32) entries.clear()
        entries[uri] = Entry(key, keyHex, userAgent)
    }

    fun get(uri: String): Entry? = entries[uri]

    private fun decodeHex(hex: String): ByteArray? {
        val clean = hex.trim()
        if (clean.length < 32 || clean.length % 2 != 0) return null
        val out = ByteArray(clean.length / 2)
        for (i in out.indices) {
            val value = clean.substring(i * 2, i * 2 + 2).toIntOrNull(16) ?: return null
            out[i] = value.toByte()
        }
        return out
    }
}
