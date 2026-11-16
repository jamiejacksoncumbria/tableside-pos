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
        startForeground(
            NOTIFICATION_ID,
            notification(runtimeReady = false, standby = false),
        )
        acquireLocks()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val runtimeReady = intent?.getBooleanExtra(EXTRA_RUNTIME_READY, false) == true
        val standby = intent?.getBooleanExtra(EXTRA_STANDBY, false) == true
        val preferences = getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        val requestedMode = intent?.getStringExtra(EXTRA_MODE)
            ?: preferences.getString(KEY_MODE, MODE_CLIENT)
            ?: MODE_CLIENT
        // Hub, printer, and ordinary-terminal requirements are independent.
        // A printer must not lose its wake locks when the UI changes session,
        // and stopping printer mode must never revoke hub authority.
        when (requestedMode) {
            MODE_HUB -> preferences.edit().putBoolean(KEY_HUB_ENABLED, true).apply()
            MODE_PRINTER -> preferences.edit().putBoolean(KEY_PRINTER_ENABLED, true).apply()
            MODE_CLIENT -> preferences.edit().putBoolean(KEY_CLIENT_ENABLED, true).apply()
        }
        val mode = effectiveMode(preferences)
        preferences.edit()
            .putString(KEY_MODE, mode)
            // Retain the legacy key while installed builds migrate to the
            // independent role flags. It represents hub authority only.
            .putBoolean(KEY_ENABLED, preferences.getBoolean(KEY_HUB_ENABLED, false))
            .apply()
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(
            NOTIFICATION_ID,
            notification(
                runtimeReady,
                standby,
                client = mode == MODE_CLIENT,
                printer = mode == MODE_PRINTER,
            ),
        )
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

    private fun notification(
        runtimeReady: Boolean,
        standby: Boolean,
        client: Boolean = false,
        printer: Boolean = false,
    ) = NotificationCompat.Builder(this, CHANNEL_ID)
        .setSmallIcon(R.mipmap.ic_launcher)
        .setContentTitle(
            when {
                client -> "TableSideCY terminal connection is active"
                printer && runtimeReady -> "TableSideCY printer service is active"
                printer -> "Open TableSideCY to restore printing"
                standby -> "TableSideCY backup hub is on standby"
                runtimeReady -> "TableSideCY venue hub is active"
                else -> "Open TableSideCY to restore the venue hub"
            },
        )
        .setContentText(
            when {
                client -> "Keeping secure venue hub ordering connected"
                printer && runtimeReady -> "Keeping the Bluetooth print queue awake"
                printer -> "Tap here before the venue sends new tickets"
                standby -> "Monitoring the primary hub for secure failover"
                runtimeReady -> "Keeping local ordering and printing available"
                else -> "The device restarted; tap here before tills take orders"
            },
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
        private const val KEY_HUB_ENABLED = "hubEnabled"
        private const val KEY_PRINTER_ENABLED = "printerEnabled"
        private const val KEY_CLIENT_ENABLED = "clientEnabled"
        private const val KEY_MODE = "mode"
        private const val EXTRA_RUNTIME_READY = "runtimeReady"
        private const val EXTRA_STANDBY = "standby"
        private const val EXTRA_MODE = "mode"
        private const val MODE_HUB = "hub"
        private const val MODE_PRINTER = "printer"
        private const val MODE_CLIENT = "client"

        @Volatile
        var isRunning: Boolean = false
            private set

        fun start(context: Context, runtimeReady: Boolean, standby: Boolean = false) {
            val intent = Intent(context, VenueHubForegroundService::class.java).apply {
                putExtra(EXTRA_RUNTIME_READY, runtimeReady)
                putExtra(EXTRA_STANDBY, standby)
                putExtra(EXTRA_MODE, MODE_HUB)
            }
            ContextCompat.startForegroundService(context, intent)
        }

        fun startClient(context: Context) {
            val intent = Intent(context, VenueHubForegroundService::class.java).apply {
                putExtra(EXTRA_RUNTIME_READY, true)
                putExtra(EXTRA_MODE, MODE_CLIENT)
            }
            ContextCompat.startForegroundService(context, intent)
        }

        fun startPrinter(context: Context, runtimeReady: Boolean = true) {
            val intent = Intent(context, VenueHubForegroundService::class.java).apply {
                putExtra(EXTRA_RUNTIME_READY, runtimeReady)
                putExtra(EXTRA_MODE, MODE_PRINTER)
            }
            ContextCompat.startForegroundService(context, intent)
        }

        fun stopClient(context: Context) {
            val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            preferences.edit().putBoolean(KEY_CLIENT_ENABLED, false).apply()
            refreshOrStop(context)
        }

        fun stopPrinter(context: Context) {
            val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            preferences.edit().putBoolean(KEY_PRINTER_ENABLED, false).apply()
            refreshOrStop(context)
        }

        fun stop(context: Context) {
            val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            preferences
                .edit()
                .putBoolean(KEY_ENABLED, false)
                .putBoolean(KEY_HUB_ENABLED, false)
                .apply()
            // The workspace may still be open as a normal POS terminal. Drop
            // hub authority without dropping its lock-screen connectivity;
            // the mounted Flutter client host stops this service on sign-out.
            startClient(context)
        }

        fun wasEnabled(context: Context): Boolean =
            context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).let { preferences ->
                preferences.getBoolean(KEY_HUB_ENABLED, false) ||
                    preferences.getBoolean(KEY_ENABLED, false)
            }

        fun wasPrinterEnabled(context: Context): Boolean =
            context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
                .getBoolean(KEY_PRINTER_ENABLED, false)

        private fun effectiveMode(preferences: android.content.SharedPreferences): String =
            when {
                preferences.getBoolean(KEY_HUB_ENABLED, false) ||
                    preferences.getBoolean(KEY_ENABLED, false) -> MODE_HUB
                preferences.getBoolean(KEY_PRINTER_ENABLED, false) -> MODE_PRINTER
                preferences.getBoolean(KEY_CLIENT_ENABLED, false) -> MODE_CLIENT
                else -> MODE_CLIENT
            }

        private fun refreshOrStop(context: Context) {
            val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            when (effectiveMode(preferences)) {
                MODE_HUB -> start(context, runtimeReady = true)
                MODE_PRINTER -> startPrinter(context)
                MODE_CLIENT -> {
                    if (preferences.getBoolean(KEY_CLIENT_ENABLED, false)) {
                        startClient(context)
                    } else {
                        preferences.edit().remove(KEY_MODE).apply()
                        context.stopService(Intent(context, VenueHubForegroundService::class.java))
                    }
                }
            }
        }
    }
}
