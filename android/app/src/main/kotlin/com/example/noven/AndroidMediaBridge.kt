package com.example.noven

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import android.util.Size
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors

class AndroidMediaBridge(private val activity: Activity) :
    MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL_NAME = "com.example.noven/android_media"
        private const val PREFS_NAME = "noven_perm_prefs"
        private const val REQUEST_AUDIO_PERMISSION = 4401
        private const val REQUEST_NOTIFICATION_PERMISSION = 4402
        private val SUPPORTED_EXTENSIONS = setOf(
            "mp3",
            "flac",
            "wav",
            "ogg",
            "opus",
            "m4a",
        )
    }

    private var channel: MethodChannel? = null
    private var pendingAudioResult: MethodChannel.Result? = null
    private var pendingNotificationResult: MethodChannel.Result? = null
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    fun register(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL_NAME).also {
            it.setMethodCallHandler(this)
        }
    }

    fun dispose() {
        channel?.setMethodCallHandler(null)
        channel = null
        pendingAudioResult = null
        pendingNotificationResult = null
        executor.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "checkAudioPermission" -> result.success(checkPermissionStatus(audioPermissionName()))
            "requestAudioPermission" -> requestAudioPermission(result)
            "checkNotificationPermission" -> {
                val perm = notificationPermissionName()
                if (perm == null) {
                    result.success("granted")
                } else {
                    result.success(checkPermissionStatus(perm))
                }
            }
            "requestNotificationPermission" -> requestNotificationPermission(result)
            "openAppSettings" -> result.success(openAppSettings())
            "scanMediaStoreAudio" -> {
                val coverDirPath = call.argument<String>("coverDirPath")
                scanMediaStoreAudio(coverDirPath, result)
            }
            "materializeContentUri" -> {
                val uri = call.argument<String>("uri")
                val cacheDirPath = call.argument<String>("cacheDirPath")
                materializeContentUri(uri, cacheDirPath, result)
            }
            else -> result.notImplemented()
        }
    }

    private fun audioPermissionName(): String {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.READ_MEDIA_AUDIO
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }
    }

    private fun notificationPermissionName(): String? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.POST_NOTIFICATIONS
        } else {
            null
        }
    }

    private fun prefs() =
        activity.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private fun hasAskedPermission(permission: String): Boolean =
        prefs().getBoolean("asked_$permission", false)

    private fun markAskedPermission(permission: String) {
        prefs().edit().putBoolean("asked_$permission", true).apply()
    }

    private fun checkPermissionStatus(permission: String): String {
        val granted = ContextCompat.checkSelfPermission(activity, permission) ==
            PackageManager.PERMISSION_GRANTED
        if (granted) return "granted"

        val askedBefore = hasAskedPermission(permission)
        val shouldShowRationale =
            ActivityCompat.shouldShowRequestPermissionRationale(activity, permission)
        return if (askedBefore && !shouldShowRationale) {
            "permanentlyDenied"
        } else {
            "denied"
        }
    }

    private fun requestAudioPermission(result: MethodChannel.Result) {
        val permission = audioPermissionName()
        if (ContextCompat.checkSelfPermission(activity, permission) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success("granted")
            return
        }
        if (pendingAudioResult != null) {
            result.error("PERMISSION_IN_PROGRESS", "Audio permission request already active", null)
            return
        }
        pendingAudioResult = result
        markAskedPermission(permission)
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(permission),
            REQUEST_AUDIO_PERMISSION,
        )
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        val permission = notificationPermissionName()
        if (permission == null ||
            ContextCompat.checkSelfPermission(activity, permission) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success("granted")
            return
        }
        if (pendingNotificationResult != null) {
            result.error(
                "PERMISSION_IN_PROGRESS",
                "Notification permission request already active",
                null,
            )
            return
        }
        pendingNotificationResult = result
        markAskedPermission(permission)
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(permission),
            REQUEST_NOTIFICATION_PERMISSION,
        )
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        when (requestCode) {
            REQUEST_AUDIO_PERMISSION -> {
                val pending = pendingAudioResult ?: return false
                pendingAudioResult = null
                val permission = permissions.firstOrNull() ?: audioPermissionName()
                val granted = grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED
                if (granted) {
                    pending.success("granted")
                } else {
                    val shouldShow = ActivityCompat.shouldShowRequestPermissionRationale(
                        activity,
                        permission,
                    )
                    pending.success(if (shouldShow) "denied" else "permanentlyDenied")
                }
                return true
            }
            REQUEST_NOTIFICATION_PERMISSION -> {
                val pending = pendingNotificationResult ?: return false
                pendingNotificationResult = null
                val permission = permissions.firstOrNull() ?: notificationPermissionName()
                val granted = grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED
                if (granted || permission == null) {
                    pending.success("granted")
                } else {
                    val shouldShow = ActivityCompat.shouldShowRequestPermissionRationale(
                        activity,
                        permission,
                    )
                    pending.success(if (shouldShow) "denied" else "permanentlyDenied")
                }
                return true
            }
            else -> return false
        }
    }

    private fun openAppSettings(): Boolean {
        return try {
            val intent = Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", activity.packageName, null),
            ).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            activity.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun scanMediaStoreAudio(
        coverDirPath: String?,
        result: MethodChannel.Result,
    ) {
        val perm = audioPermissionName()
        if (ContextCompat.checkSelfPermission(activity, perm) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            result.error("PERMISSION_DENIED", "Audio permission not granted", null)
            return
        }

        val appContext = activity.applicationContext
        executor.execute {
            try {
                val items = queryMediaStoreTracks(appContext, coverDirPath)
                mainHandler.post { result.success(items) }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error(
                        "SCAN_FAILED",
                        e.message ?: "Failed to scan MediaStore audio",
                        null,
                    )
                }
            }
        }
    }

    private fun queryMediaStoreTracks(
        context: Context,
        coverDirPath: String?,
    ): List<Map<String, Any?>> {
        val resolver = context.contentResolver
        val collection = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.DATA,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.ALBUM_ID,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.SIZE,
            MediaStore.Audio.Media.DISPLAY_NAME,
            MediaStore.Audio.Media.DATE_ADDED,
            MediaStore.Audio.Media.IS_MUSIC,
        )

        val tracks = ArrayList<Map<String, Any?>>()
        val albumCoverCache = HashMap<Long, String?>()
        val coverDir = coverDirPath?.takeIf { it.isNotBlank() }?.let { File(it) }
        if (coverDir != null && !coverDir.exists()) {
            coverDir.mkdirs()
        }

        val sortOrder = "${MediaStore.Audio.Media.DATE_ADDED} ASC, ${MediaStore.Audio.Media.TITLE} ASC"
        resolver.query(collection, projection, null, null, sortOrder)?.use { cursor ->
            val idCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
            val dataCol = cursor.getColumnIndex(MediaStore.Audio.Media.DATA)
            val titleCol = cursor.getColumnIndex(MediaStore.Audio.Media.TITLE)
            val artistCol = cursor.getColumnIndex(MediaStore.Audio.Media.ARTIST)
            val albumCol = cursor.getColumnIndex(MediaStore.Audio.Media.ALBUM)
            val albumIdCol = cursor.getColumnIndex(MediaStore.Audio.Media.ALBUM_ID)
            val durationCol = cursor.getColumnIndex(MediaStore.Audio.Media.DURATION)
            val sizeCol = cursor.getColumnIndex(MediaStore.Audio.Media.SIZE)
            val displayNameCol = cursor.getColumnIndex(MediaStore.Audio.Media.DISPLAY_NAME)
            val dateAddedCol = cursor.getColumnIndex(MediaStore.Audio.Media.DATE_ADDED)
            val isMusicCol = cursor.getColumnIndex(MediaStore.Audio.Media.IS_MUSIC)

            while (cursor.moveToNext()) {
                val id = cursor.getLong(idCol)
                val dataPath = if (dataCol >= 0) cursor.getString(dataCol) else null
                val displayName =
                    if (displayNameCol >= 0) cursor.getString(displayNameCol) else null
                val candidateName = (dataPath ?: displayName ?: "").lowercase()
                val ext = candidateName.substringAfterLast('.', "")
                if (ext !in SUPPORTED_EXTENSIONS) continue

                val lowerPath = (dataPath ?: "").lowercase()
                val isMusic = if (isMusicCol >= 0) cursor.getInt(isMusicCol) else 1
                if (isMusic == 0 &&
                    (lowerPath.contains("/ringtones/") ||
                        lowerPath.contains("/notifications/") ||
                        lowerPath.contains("/alarms/"))
                ) {
                    continue
                }

                val durationMs = if (durationCol >= 0) cursor.getLong(durationCol) else 0L
                if (durationMs in 1..999) continue

                val sizeBytes = if (sizeCol >= 0) cursor.getLong(sizeCol) else 0L
                val trackUri = ContentUris.withAppendedId(collection, id)

                val readablePath = dataPath?.takeIf {
                    it.isNotBlank() && File(it).canRead()
                }
                val pathOrUri = readablePath ?: trackUri.toString()

                val rawTitle = if (titleCol >= 0) cursor.getString(titleCol) else null
                val fallbackTitle = (displayName ?: pathOrUri.substringAfterLast('/'))
                    .replace(Regex("\\.[^.]+$"), "")
                val title = rawTitle?.trim()?.takeIf { it.isNotEmpty() } ?: fallbackTitle

                val rawArtist = if (artistCol >= 0) cursor.getString(artistCol) else null
                val artist = rawArtist?.trim()?.takeIf {
                    it.isNotEmpty() && !it.equals("<unknown>", ignoreCase = true)
                } ?: "Unknown Artist"

                val rawAlbum = if (albumCol >= 0) cursor.getString(albumCol) else null
                val album = rawAlbum?.trim()?.takeIf {
                    it.isNotEmpty() && !it.equals("<unknown>", ignoreCase = true)
                }

                val albumId = if (albumIdCol >= 0) cursor.getLong(albumIdCol) else -1L
                val coverPath = if (coverDir != null && albumId > 0) {
                    albumCoverCache.getOrPut(albumId) {
                        extractAlbumCover(resolver, trackUri, albumId, coverDir)
                    }
                } else {
                    null
                }

                val dateAddedSec = if (dateAddedCol >= 0) cursor.getLong(dateAddedCol) else 0L
                val addedAtMs = if (dateAddedSec > 0) dateAddedSec * 1000L else null

                tracks.add(
                    mapOf(
                        "path" to pathOrUri,
                        "contentUri" to trackUri.toString(),
                        "title" to title,
                        "artist" to artist,
                        "album" to album,
                        "durationMs" to (if (durationMs > 0) durationMs else null),
                        "sizeBytes" to (if (sizeBytes > 0) sizeBytes else null),
                        "coverPath" to coverPath,
                        "addedAtMs" to addedAtMs,
                    ),
                )
            }
        }
        return tracks
    }

    private fun extractAlbumCover(
        resolver: android.content.ContentResolver,
        trackUri: Uri,
        albumId: Long,
        coverDir: File,
    ): String? {
        val target = File(coverDir, "ms_album_$albumId.jpg")
        if (target.exists() && target.length() > 0L) {
            return target.absolutePath
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return null
        }

        return try {
            val bitmap = resolver.loadThumbnail(trackUri, Size(512, 512), null)
            val tmp = File(coverDir, "ms_album_$albumId.jpg.tmp")
            FileOutputStream(tmp).use { out ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 88, out)
                out.flush()
            }
            bitmap.recycle()
            if (target.exists()) {
                target.delete()
            }
            if (tmp.renameTo(target)) {
                target.absolutePath
            } else {
                tmp.delete()
                null
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun materializeContentUri(
        uriString: String?,
        cacheDirPath: String?,
        result: MethodChannel.Result,
    ) {
        if (uriString.isNullOrBlank() || cacheDirPath.isNullOrBlank()) {
            result.success(null)
            return
        }

        val appContext = activity.applicationContext
        executor.execute {
            try {
                val cacheDir = File(cacheDirPath)
                if (!cacheDir.exists()) {
                    cacheDir.mkdirs()
                }
                cacheDir.listFiles()?.forEach { existing ->
                    if (existing.name.startsWith("active_playback")) {
                        existing.delete()
                    }
                }

                val parsedUri = Uri.parse(uriString)
                val mime = appContext.contentResolver.getType(parsedUri)?.lowercase() ?: ""
                val ext = when {
                    mime.contains("flac") -> "flac"
                    mime.contains("ogg") -> "ogg"
                    mime.contains("opus") -> "opus"
                    mime.contains("wav") -> "wav"
                    mime.contains("mp4") || mime.contains("m4a") || mime.contains("aac") -> "m4a"
                    else -> "mp3"
                }

                val outFile = File(cacheDir, "active_playback.$ext")
                appContext.contentResolver.openInputStream(parsedUri)?.use { input ->
                    FileOutputStream(outFile).use { output ->
                        input.copyTo(output, bufferSize = 64 * 1024)
                        output.flush()
                    }
                } ?: run {
                    mainHandler.post { result.success(null) }
                    return@execute
                }

                mainHandler.post { result.success(outFile.absolutePath) }
            } catch (_: Exception) {
                mainHandler.post { result.success(null) }
            }
        }
    }
}
