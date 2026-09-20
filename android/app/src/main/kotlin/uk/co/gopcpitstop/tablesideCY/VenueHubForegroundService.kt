package uk.co.gopcpitstop.tablesideCY

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

class VenueHubForegroundService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, notification(runtimeReady = false))
        acquireLocks()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val runtimeReady = intent?.getBooleanExtra(EXTRA_RUNTIME_READY, false) == true
        getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_ENABLED, true)
            .apply()
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, notification(runtimeReady))
        return START_STICKY
    }

    override fun onDestroy() {
        wifiLock?.takeIf { it.isHeld }?.release()
        wakeLock?.takeIf { it.isHeld }?.release()
        wifiLock = null
        wakeLock = null
        isRunning = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun acquireLocks() {
        val powerManager = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "$packageName:venueHubCpu",
        ).apply {
            setReferenceCounted(false)
            acquire()
        }
        val wifiManager = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
        wifiLock = wifiManager.createWifiLock(
            WifiManager.WIFI_MODE_FULL_HIGH_PERF,
            "$packageName:venueHubWifi",
        ).apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun notification(runtimeReady: Boolean) = NotificationCompat.Builder(this, CHANNEL_ID)
        .setSmallIcon(R.mipmap.ic_launcher)
        .setContentTitle(
            if (runtimeReady) "TableSideCY venue hub is active"
            else "Open TableSideCY to restore the venue hub",
        )
        .setContentText(
            if (runtimeReady) "Keeping local ordering and printing available"
            else "The device restarted; tap here before tills take orders",
        )
        .setContentIntent(
            PendingIntent.getActivity(
                this,
                0,
                Intent(this, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            ),
        )
        .setOngoing(true)
        .setOnlyAlertOnce(true)
        .setCategory(NotificationCompat.CATEGORY_SERVICE)
        .build()

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Venue hub",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Keeps venue ordering and printing active on the local network"
                setShowBadge(false)
            },
        )
    }

    companion object {
        private const val CHANNEL_ID = "tableside_venue_hub"
        private const val NOTIFICATION_ID = 4811
        private const val PREFERENCES = "tableside_venue_hub"
        private const val KEY_ENABLED = "enabled"
        private const val EXTRA_RUNTIME_READY = "runtimeReady"

        @Volatile
        var isRunning: Boolean = false
            private set

        fun start(context: Context, runtimeReady: Boolean) {
            val intent = Intent(context, VenueHubForegroundService::class.java).apply {
                putExtra(EXTRA_RUNTIME_READY, runtimeReady)
            }
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(KEY_ENABLED, false)
                .apply()
            context.stopService(Intent(context, VenueHubForegroundService::class.java))
        }

        fun wasEnabled(context: Context): Boolean =
            context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
                .getBoolean(KEY_ENABLED, false)
    }
}
