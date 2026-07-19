package aieco.light.mesh

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.net.wifi.WifiManager

class MeshBackgroundService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onCreate() {
        super.onCreate()
        MeshNotifications.ensureChannels(this)
        acquireMeshLocks()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = MeshNotifications.backgroundNotification(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                MeshNotifications.BACKGROUND_NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(MeshNotifications.BACKGROUND_NOTIFICATION_ID, notification)
        }
        return START_STICKY
    }

    override fun onDestroy() {
        releaseMeshLocks()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun acquireMeshLocks() {
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "aieco_mesh:background_cpu"
        ).apply {
            setReferenceCounted(false)
            acquire()
        }

        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        @Suppress("DEPRECATION")
        wifiLock = wifiManager.createWifiLock(
            WifiManager.WIFI_MODE_FULL_HIGH_PERF,
            "aieco_mesh:background_wifi"
        ).apply {
            setReferenceCounted(false)
            acquire()
        }
        multicastLock = wifiManager.createMulticastLock(
            "aieco_mesh:background_multicast"
        ).apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseMeshLocks() {
        runCatching { multicastLock?.takeIf { it.isHeld }?.release() }
        runCatching { wifiLock?.takeIf { it.isHeld }?.release() }
        runCatching { wakeLock?.takeIf { it.isHeld }?.release() }
        multicastLock = null
        wifiLock = null
        wakeLock = null
    }
}

object MeshNotifications {
    const val BACKGROUND_NOTIFICATION_ID = 47880
    private const val CHAT_NOTIFICATION_ID = 47881
    private const val BACKGROUND_CHANNEL_ID = "aieco_mesh_background"
    private const val CHAT_CHANNEL_ID = "aieco_mesh_chat"

    fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }

        val manager = notificationManager(context)
        val backgroundChannel = NotificationChannel(
            BACKGROUND_CHANNEL_ID,
            "光之網絡背景作業",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "保持傳播光在背景接收和轉發訊息。"
            setShowBadge(false)
        }
        val chatChannel = NotificationChannel(
            CHAT_CHANNEL_ID,
            "傳播光新留言",
            NotificationManager.IMPORTANCE_DEFAULT
        ).apply {
            description = "縮小 APP 時顯示新留言通知。"
            setShowBadge(true)
        }
        manager.createNotificationChannel(backgroundChannel)
        manager.createNotificationChannel(chatChannel)
    }

    fun backgroundNotification(context: Context): Notification {
        ensureChannels(context)
        return builder(context, BACKGROUND_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("傳播光正在背景運作")
            .setContentText("光之網絡保持連線，新留言會以通知提示。")
            .setContentIntent(launchPendingIntent(context))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setLocalOnly(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setPriority(Notification.PRIORITY_LOW)
            .build()
    }

    fun showChatNotification(context: Context, title: String, text: String): Boolean {
        if (!notificationsAllowed(context)) {
            return false
        }

        ensureChannels(context)
        val notification = builder(context, CHAT_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setContentIntent(launchPendingIntent(context))
            .setAutoCancel(true)
            .setShowWhen(true)
            .setWhen(System.currentTimeMillis())
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setPriority(Notification.PRIORITY_DEFAULT)
            .build()

        return runCatching {
            notificationManager(context).notify(CHAT_NOTIFICATION_ID, notification)
        }.isSuccess
    }

    fun clearChatNotifications(context: Context) {
        runCatching {
            notificationManager(context).cancel(CHAT_NOTIFICATION_ID)
        }
    }

    private fun builder(context: Context, channelId: String): Notification.Builder {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, channelId)
        } else {
            Notification.Builder(context)
        }
    }

    private fun launchPendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }
        return PendingIntent.getActivity(context, 0, intent, flags)
    }

    private fun notificationsAllowed(context: Context): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun notificationManager(context: Context): NotificationManager {
        return context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    }
}
