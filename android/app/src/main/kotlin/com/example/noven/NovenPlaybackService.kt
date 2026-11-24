package com.example.noven

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import java.io.File

class NovenPlaybackService : Service() {

    companion object {
        const val CHANNEL_ID = "noven_media_playback"
        const val NOTIFICATION_ID = 4409

        const val ACTION_UPDATE_STATE = "com.example.noven.action.UPDATE_STATE"
        const val ACTION_STOP_SERVICE = "com.example.noven.action.STOP_SERVICE"
        const val ACTION_MEDIA_PLAY_PAUSE = "com.example.noven.action.PLAY_PAUSE"
        const val ACTION_MEDIA_NEXT = "com.example.noven.action.NEXT"
        const val ACTION_MEDIA_PREVIOUS = "com.example.noven.action.PREVIOUS"
        const val ACTION_MEDIA_STOP = "com.example.noven.action.STOP"

        const val EXTRA_TITLE = "title"
        const val EXTRA_ARTIST = "artist"
        const val EXTRA_ALBUM = "album"
        const val EXTRA_DURATION_MS = "durationMs"
        const val EXTRA_POSITION_MS = "positionMs"
        const val EXTRA_IS_PLAYING = "isPlaying"
        const val EXTRA_COVER_PATH = "coverPath"

        private const val SUPPORTED_SESSION_ACTIONS =
            PlaybackState.ACTION_PLAY or
                PlaybackState.ACTION_PAUSE or
                PlaybackState.ACTION_PLAY_PAUSE or
                PlaybackState.ACTION_SKIP_TO_NEXT or
                PlaybackState.ACTION_SKIP_TO_PREVIOUS or
                PlaybackState.ACTION_SEEK_TO or
                PlaybackState.ACTION_STOP

        @Volatile
        var actionListener: ((action: String, positionMs: Long?) -> Unit)? = null
    }

    private var mediaSession: MediaSession? = null
    private var isForeground = false
    private var currentIsPlaying = false
    private var cachedCoverPath: String? = null
    private var cachedCoverBitmap: Bitmap? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        mediaSession = MediaSession(this, "NovenMediaSession").apply {
            @Suppress("DEPRECATION")
            setFlags(
                MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or
                    MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS,
            )
            setCallback(
                object : MediaSession.Callback() {
                    override fun onPlay() {
                        actionListener?.invoke("play", null)
                    }

                    override fun onPause() {
                        actionListener?.invoke("pause", null)
                    }

                    override fun onSkipToNext() {
                        actionListener?.invoke("next", null)
                    }

                    override fun onSkipToPrevious() {
                        actionListener?.invoke("previous", null)
                    }

                    override fun onSeekTo(pos: Long) {
                        actionListener?.invoke("seek", pos.coerceAtLeast(0L))
                    }

                    override fun onStop() {
                        actionListener?.invoke("stop", null)
                    }
                },
            )
            isActive = true
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_UPDATE_STATE -> handleUpdateState(intent)
            ACTION_MEDIA_PLAY_PAUSE -> {
                actionListener?.invoke(
                    if (currentIsPlaying) "pause" else "play",
                    null,
                )
            }
            ACTION_MEDIA_NEXT -> actionListener?.invoke("next", null)
            ACTION_MEDIA_PREVIOUS -> actionListener?.invoke("previous", null)
            ACTION_MEDIA_STOP -> {
                actionListener?.invoke("stop", null)
                stopServiceCleanly()
            }
            ACTION_STOP_SERVICE -> stopServiceCleanly()
        }
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        stopServiceCleanly()
        super.onTaskRemoved(rootIntent)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        mediaSession?.isActive = false
        mediaSession?.release()
        mediaSession = null
        cachedCoverPath = null
        cachedCoverBitmap = null
        try {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            manager?.cancel(NOTIFICATION_ID)
        } catch (_: Exception) {}
        super.onDestroy()
    }

    private fun handleUpdateState(intent: Intent) {
        val title = intent.getStringExtra(EXTRA_TITLE)?.takeIf { it.isNotBlank() } ?: "Noven"
        val artist = intent.getStringExtra(EXTRA_ARTIST)?.takeIf { it.isNotBlank() }
            ?: "Unknown Artist"
        val album = intent.getStringExtra(EXTRA_ALBUM)?.takeIf { it.isNotBlank() }
        val durationMs = intent.getLongExtra(EXTRA_DURATION_MS, 0L).coerceAtLeast(0L)
        val positionMs = intent.getLongExtra(EXTRA_POSITION_MS, 0L).coerceAtLeast(0L)
        val isPlaying = intent.getBooleanExtra(EXTRA_IS_PLAYING, false)
        val coverPath = intent.getStringExtra(EXTRA_COVER_PATH)

        currentIsPlaying = isPlaying
        val coverBitmap = loadCoverBitmap(coverPath)

        mediaSession?.let { session ->
            session.isActive = true
            val metadataBuilder = MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, title)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, artist)
                .putLong(MediaMetadata.METADATA_KEY_DURATION, durationMs)
            if (album != null) {
                metadataBuilder.putString(MediaMetadata.METADATA_KEY_ALBUM, album)
            }
            if (coverBitmap != null) {
                metadataBuilder.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, coverBitmap)
            }
            session.setMetadata(metadataBuilder.build())

            val playbackState = PlaybackState.Builder()
                .setActions(SUPPORTED_SESSION_ACTIONS)
                .setState(
                    if (isPlaying) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                    positionMs,
                    if (isPlaying) 1.0f else 0.0f,
                    SystemClock.elapsedRealtime(),
                )
                .build()
            session.setPlaybackState(playbackState)
        }

        val notification = buildNotification(
            title = title,
            artist = artist,
            album = album,
            isPlaying = isPlaying,
            coverBitmap = coverBitmap,
        )

        if (isPlaying) {
            startForegroundCompat(notification)
        } else {
            detachForegroundIfActive()
            notifySafely(notification)
        }
    }

    private fun buildNotification(
        title: String,
        artist: String,
        album: String?,
        isPlaying: Boolean,
        coverBitmap: Bitmap?,
    ): Notification {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentIntent = PendingIntent.getActivity(
            this,
            100,
            launchIntent,
            pendingIntentFlags(),
        )
        val deleteIntent = createServicePendingIntent(101, ACTION_STOP_SERVICE)

        val prevAction = Notification.Action.Builder(
            Icon.createWithResource(this, R.drawable.ic_media_prev),
            "Previous",
            createServicePendingIntent(102, ACTION_MEDIA_PREVIOUS),
        ).build()

        val playPauseAction = Notification.Action.Builder(
            Icon.createWithResource(
                this,
                if (isPlaying) R.drawable.ic_media_pause else R.drawable.ic_media_play,
            ),
            if (isPlaying) "Pause" else "Play",
            createServicePendingIntent(103, ACTION_MEDIA_PLAY_PAUSE),
        ).build()

        val nextAction = Notification.Action.Builder(
            Icon.createWithResource(this, R.drawable.ic_media_next),
            "Next",
            createServicePendingIntent(104, ACTION_MEDIA_NEXT),
        ).build()

        val style = Notification.MediaStyle().setShowActionsInCompactView(0, 1, 2)
        mediaSession?.sessionToken?.let { style.setMediaSession(it) }

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        builder
            .setSmallIcon(R.drawable.ic_stat_noven_music)
            .setContentTitle(title)
            .setContentText(artist)
            .setColor(0xFF7B61FF.toInt())
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setCategory(Notification.CATEGORY_TRANSPORT)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setOngoing(isPlaying)
            .setContentIntent(contentIntent)
            .setDeleteIntent(deleteIntent)
            .setStyle(style)
            .addAction(prevAction)
            .addAction(playPauseAction)
            .addAction(nextAction)

        if (album != null) {
            builder.setSubText(album)
        }
        if (coverBitmap != null) {
            builder.setLargeIcon(coverBitmap)
        }

        return builder.build()
    }

    private fun startForegroundCompat(notification: Notification) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            isForeground = true
        } catch (_: Exception) {
            isForeground = false
            notifySafely(notification)
        }
    }

    private fun detachForegroundIfActive() {
        if (!isForeground) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_DETACH)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(false)
        }
        isForeground = false
    }

    private fun notifySafely(notification: Notification) {
        try {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            manager?.notify(NOTIFICATION_ID, notification)
        } catch (_: SecurityException) {
        } catch (_: Exception) {
        }
    }

    private fun stopServiceCleanly() {
        currentIsPlaying = false
        mediaSession?.let { session ->
            session.isActive = false
            session.setPlaybackState(
                PlaybackState.Builder()
                    .setState(PlaybackState.STATE_STOPPED, 0L, 0f)
                    .build(),
            )
        }
        if (isForeground) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            isForeground = false
        }
        try {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            manager?.cancel(NOTIFICATION_ID)
        } catch (_: Exception) {}
        stopSelf()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return

        val channel = NotificationChannel(
            CHANNEL_ID,
            "Pemutaran Musik",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Menampilkan lagu yang sedang diputar dan kontrol media Noven."
            setShowBadge(false)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        manager.createNotificationChannel(channel)
    }

    private fun createServicePendingIntent(requestCode: Int, action: String): PendingIntent {
        val intent = Intent(this, NovenPlaybackService::class.java).setAction(action)
        return PendingIntent.getService(this, requestCode, intent, pendingIntentFlags())
    }

    private fun pendingIntentFlags(): Int {
        return PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    }

    private fun loadCoverBitmap(coverPath: String?): Bitmap? {
        val normalized = coverPath?.trim()?.takeIf { it.isNotEmpty() }
        if (normalized == null) {
            cachedCoverPath = null
            cachedCoverBitmap = null
            return null
        }
        if (normalized == cachedCoverPath && cachedCoverBitmap != null) {
            return cachedCoverBitmap
        }
        val file = File(normalized)
        if (!file.exists() || !file.isFile) {
            cachedCoverPath = null
            cachedCoverBitmap = null
            return null
        }

        val decoded = try {
            val bounds = BitmapFactory.Options().apply {
                inJustDecodeBounds = true
            }
            BitmapFactory.decodeFile(normalized, bounds)
            val maxDim = maxOf(bounds.outWidth, bounds.outHeight)
            var sampleSize = 1
            while (maxDim / sampleSize > 512) {
                sampleSize *= 2
            }
            val opts = BitmapFactory.Options().apply {
                inSampleSize = sampleSize
                inPreferredConfig = Bitmap.Config.ARGB_8888
            }
            BitmapFactory.decodeFile(normalized, opts)
        } catch (_: Exception) {
            null
        }

        cachedCoverPath = if (decoded != null) normalized else null
        cachedCoverBitmap = decoded
        return decoded
    }
}
