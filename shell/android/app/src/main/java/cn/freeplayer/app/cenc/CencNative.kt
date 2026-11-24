package cn.freeplayer.app.cenc

/**
 * Raw binding to the portable CENC core built from native/cenc (the same
 * fp_cenc_* exports the desktop client binds through dart:ffi).
 *
 * The class and method names are part of the JNI contract; keep them when
 * touching proguard-rules.pro.
 */
object CencNative {
    init {
        System.loadLibrary("cenc_decrypt")
    }

    external fun nativeIndexCreate(data: ByteArray, base: Long, fileSize: Long): Long

    external fun nativeIndexSpan(handle: Long, start: Long, end: Long, out: LongArray): Int

    external fun nativeDecrypt(handle: Long, key: ByteArray, buffer: ByteArray, start: Long): Int

    external fun nativeIndexFree(handle: Long)

    external fun nativeIndexError(): String
}
