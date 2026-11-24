package cn.freeplayer.app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import cn.freeplayer.app.bvc2.Bvc2Player
import cn.freeplayer.app.cenc.CencMedia
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android host for the Flutter shell.
 *
 * The media stack (libmpv) cannot open SAF `content://` URIs, so picked and
 * shared videos are copied into the app cache and handed to Dart as real
 * paths. `freeplayer://source?url=…` links and "open with" intents arrive
 * through the same channel the desktop command line feeds.
 */
class MainActivity : FlutterActivity() {
    private companion object {
        const val CHANNEL = "free_player/android"
        const val REQUEST_PICK_VIDEOS = 1001
        const val TAG = "FreePlayer"
    }

    private var channel: MethodChannel? = null
    private var pendingPick: MethodChannel.Result? = null
    private var bvc2Player: Bvc2Player? = null
    private var bvc2Events: EventChannel? = null
    private var bvc2Sink: EventChannel.EventSink? = null

    @Volatile
    private var initialResolved = false

    @Volatile
    private var initialValue: String? = null
    private val initialWaiters = mutableListOf<MethodChannel.Result>()
    private val initialStarted = AtomicBoolean(false)
    private val warmExecutor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val methodChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel = methodChannel
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "initialOpen" -> resolveInitial(result)
                "pickVideos" -> pickVideos(result)
                "openUrl" -> {
                    openUrl(call.argument<String>("url") ?: "")
                    result.success(null)
                }
                "openFolder" -> {
                    // Android has no standard intent for app-private folders;
                    // the settings screen shows the path instead.
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        val eventChannel = EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "free_player/bvc2/events",
        )
        bvc2Events = eventChannel
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                bvc2Sink = events
            }

            override fun onCancel(arguments: Any?) {
                bvc2Sink = null
            }
        })
        val player = Bvc2Player(this, flutterEngine.renderer) { event ->
            bvc2Sink?.success(event)
        }
        bvc2Player = player
        try {
            Log.i(
                TAG,
                "bvc2 probe: available=${player.isAvailable()} version=${player.version()}",
            )
        } catch (error: Throwable) {
            Log.w(TAG, "bvc2 probe failed", error)
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "free_player/bvc2",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isAvailable" -> result.success(player.isAvailable())
                "version" -> result.success(player.version())
                "open" -> {
                    val url = call.argument<String>("url") ?: ""
                    val autoPlay = call.argument<Boolean>("autoPlay") ?: true
                    val start = (call.argument<Number>("startMs") ?: 0).toLong()
                    val keyHex = call.argument<String>("keyHex") ?: ""
                    val userAgent = call.argument<String>("userAgent") ?: ""
                    try {
                        result.success(
                            player.open(url, autoPlay, start, keyHex, userAgent),
                        )
                    } catch (error: Exception) {
                        result.error("open", error.message, null)
                    }
                }
                "warm" -> {
                    val url = call.argument<String>("url") ?: ""
                    val keyHex = call.argument<String>("keyHex") ?: ""
                    val userAgent = call.argument<String>("userAgent") ?: ""
                    if (url.isEmpty() || keyHex.isEmpty()) {
                        result.success(false)
                    } else {
                        // Off the platform thread: this fetches the moov
                        // window and parses the CENC index.
                        warmExecutor.execute {
                            val ok = try {
                                CencMedia.warm(url, keyHex, userAgent)
                                true
                            } catch (error: Throwable) {
                                Log.w(TAG, "warm $url failed", error)
                                false
                            }
                            runOnUiThread { result.success(ok) }
                        }
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
                "seek" -> {
                    player.seekTo(
                        (call.argument<Number>("positionMs") ?: 0).toLong(),
                    )
                    result.success(null)
                }
                "volume" -> {
                    player.setVolume(
                        (call.argument<Number>("volume") ?: 1.0).toFloat(),
                    )
                    result.success(null)
                }
                "rate" -> {
                    player.setRate(
                        (call.argument<Number>("rate") ?: 1.0).toFloat(),
                    )
                    result.success(null)
                }
                "release" -> {
                    player.release()
                    result.success(null)
                }
                "dispose" -> {
                    player.dispose()
                    bvc2Player = null
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        bvc2Player?.dispose()
        bvc2Player = null
        bvc2Events = null
        bvc2Sink = null
        warmExecutor.shutdownNow()
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        Thread {
            val value = extractIncoming(intent) ?: return@Thread
            runOnUiThread { channel?.invokeMethod("onOpen", value) }
        }.start()
    }

    /** The intent that launched this process, resolved once and cached. */
    private fun resolveInitial(result: MethodChannel.Result) {
        if (initialResolved) {
            result.success(initialValue)
            return
        }
        initialWaiters.add(result)
        if (!initialStarted.compareAndSet(false, true)) return
        Thread {
            val value = intent?.let { extractIncoming(it) }
            runOnUiThread {
                initialValue = value
                initialResolved = true
                val waiters = initialWaiters.toList()
                initialWaiters.clear()
                for (waiter in waiters) waiter.success(value)
            }
        }.start()
    }

    /**
     * A `freeplayer://` source link stays a link; a video URI is copied to the
     * cache so the player gets a real file path.
     */
    private fun extractIncoming(intent: Intent?): String? {
        if (intent == null) return null
        val data = intent.data
        if (data != null) {
            when (data.scheme?.lowercase()) {
                "freeplayer" -> return data.toString()
                "content" -> return copyToCache(data)
                "file" -> {
                    val path = data.path
                    if (path != null && File(path).isFile) return path
                }
            }
        }
        if (intent.action == Intent.ACTION_SEND) {
            @Suppress("DEPRECATION")
            val stream = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            if (stream != null) return copyToCache(stream)
        }
        if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            @Suppress("DEPRECATION")
            val streams = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            if (!streams.isNullOrEmpty()) {
                val base = safeBaseName(displayName(streams[0]))
                val folder =
                    File(cacheDir, "incoming/$base-${System.currentTimeMillis()}")
                folder.mkdirs()
                var copied = 0
                for (stream in streams) {
                    if (copyUriTo(stream, folder) != null) copied++
                }
                if (copied > 0) return folder.absolutePath
            }
        }
        return null
    }

    private fun pickVideos(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("busy", "A picker is already open", null)
            return
        }
        pendingPick = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "video/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        try {
            startActivityForResult(intent, REQUEST_PICK_VIDEOS)
        } catch (error: Exception) {
            pendingPick = null
            result.error("unavailable", error.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_PICK_VIDEOS) return
        val result = pendingPick ?: return
        pendingPick = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(null)
            return
        }
        val uris = mutableListOf<Uri>()
        data.clipData?.let { clip ->
            for (index in 0 until clip.itemCount) {
                uris.add(clip.getItemAt(index).uri)
            }
        }
        data.data?.let { uris.add(it) }
        if (uris.isEmpty()) {
            result.success(null)
            return
        }
        Thread {
            // One pick keeps its own name; a multi-pick becomes a folder the
            // local playlist can treat as a series.
            if (uris.size == 1) {
                val folder = File(cacheDir, "picked")
                folder.mkdirs()
                val answer = copyUriTo(uris[0], folder)
                runOnUiThread { result.success(answer) }
                return@Thread
            }
            val base = safeBaseName(displayName(uris[0]))
            val folder = File(cacheDir, "picked/$base-${System.currentTimeMillis()}")
            folder.mkdirs()
            var copied = 0
            for (uri in uris) {
                if (copyUriTo(uri, folder) != null) copied++
            }
            val answer = if (copied > 0) folder.absolutePath else null
            runOnUiThread { result.success(answer) }
        }.start()
    }

    private fun copyToCache(uri: Uri): String? {
        val folder = File(cacheDir, "incoming")
        folder.mkdirs()
        return copyUriTo(uri, folder)
    }

    private fun copyUriTo(uri: Uri, folder: File): String? {
        val fallback = "video-${System.currentTimeMillis()}.mp4"
        val raw = displayName(uri) ?: fallback
        val safe = raw
            .replace(Regex("[^\\p{L}\\p{N}._ -]"), "_")
            .take(120)
            .ifBlank { fallback }
        val dot = safe.lastIndexOf('.')
        val base = if (dot > 0) safe.substring(0, dot) else safe
        // A shared stream may carry no file extension; the local playlist
        // filters by extension, so give it the common media one.
        val extension = if (dot > 0) safe.substring(dot) else ".mp4"
        var target = File(folder, if (dot > 0) safe else "$safe.mp4")
        var suffix = 1
        while (target.exists()) {
            target = File(folder, "$base-$suffix$extension")
            suffix++
        }
        return try {
            contentResolver.openInputStream(uri)?.use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            } ?: return null
            if (target.length() > 0) {
                target.absolutePath
            } else {
                target.delete()
                null
            }
        } catch (error: Exception) {
            Log.w(TAG, "copy $uri failed", error)
            target.delete()
            null
        }
    }

    private fun safeBaseName(raw: String?): String {
        val name = raw ?: "videos"
        return name.substringBeforeLast('.')
            .replace(Regex("[^\\p{L}\\p{N}._ -]"), "_")
            .take(60)
            .trim()
            .ifBlank { "videos" }
    }

    private fun displayName(uri: Uri): String? {
        return try {
            contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                if (!cursor.moveToFirst()) return@use null
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) cursor.getString(index) else null
            }
        } catch (error: Exception) {
            null
        }
    }

    private fun openUrl(url: String) {
        val uri = Uri.parse(url)
        if (uri.scheme != "http" && uri.scheme != "https") return
        try {
            startActivity(Intent(Intent.ACTION_VIEW, uri))
        } catch (error: Exception) {
            Log.w(TAG, "cannot open $url", error)
        }
    }
}
