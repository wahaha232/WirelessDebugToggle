package tw.eddie.wireless_debug_toggle

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.widget.Toast

/** 常駐通知：狀態列小圖示＋「Wi-Fi｜IP:Port」，附開關與複製按鈕 */
class StatusService : Service() {

    companion object {
        private const val CHANNEL = "status"
        private const val NOTIF_ID = 1

        fun start(ctx: Context) {
            ctx.startForegroundService(Intent(ctx, StatusService::class.java))
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, StatusService::class.java))
        }
    }

    private val listener: () -> Unit = { post() }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, "無線偵錯狀態", NotificationManager.IMPORTANCE_LOW).apply {
                setShowBadge(false)
            }
        )
        startForeground(NOTIF_ID, build(), ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        AdbWifiMonitor.acquire(this, listener)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onDestroy() {
        AdbWifiMonitor.release(listener)
        super.onDestroy()
    }

    private fun post() {
        getSystemService(NotificationManager::class.java).notify(NOTIF_ID, build())
    }

    private fun build(): Notification {
        val on = AdbWifi.isEnabled(this) == true
        val ip = AdbWifiMonitor.ip
        val port = AdbWifiMonitor.port
        val ssid = AdbWifiMonitor.ssid

        val text = when {
            ip == null -> "未連線 Wi-Fi"
            !on -> listOfNotNull(ssid, "點「開啟」啟用").joinToString("｜")
            else -> listOfNotNull(ssid, port?.let { "$ip:$it" } ?: "$ip（搜尋 Port…）").joinToString("｜")
        }

        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE
        )
        val b = Notification.Builder(this, CHANNEL)
            .setSmallIcon(if (on) R.drawable.ic_stat_on else R.drawable.ic_stat_off)
            .setContentTitle(if (on) "無線偵錯 · 已開啟" else "無線偵錯 · 已關閉")
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_STATUS)
            .setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)

        if (AdbWifi.canWrite(this)) {
            b.addAction(action(if (on) "關閉" else "開啟", ActionReceiver.TOGGLE, 1))
        }
        if (on && ip != null && port != null) {
            b.addAction(action("複製連線指令", ActionReceiver.COPY, 2))
        }
        return b.build()
    }

    private fun action(title: String, act: String, code: Int): Notification.Action {
        val pi = PendingIntent.getBroadcast(
            this, code,
            Intent(this, ActionReceiver::class.java).setAction(act),
            PendingIntent.FLAG_IMMUTABLE
        )
        return Notification.Action.Builder(null, title, pi).build()
    }
}

/** 通知按鈕：開關、複製 adb connect 指令 */
class ActionReceiver : BroadcastReceiver() {
    companion object {
        const val TOGGLE = "tw.eddie.adbwifi.TOGGLE"
        const val COPY = "tw.eddie.adbwifi.COPY"
    }

    override fun onReceive(ctx: Context, intent: Intent) {
        when (intent.action) {
            TOGGLE -> try {
                AdbWifi.setEnabled(ctx, AdbWifi.isEnabled(ctx) != true)
            } catch (e: SecurityException) {
                Toast.makeText(ctx, "尚未授權，請先用電腦執行授權指令", Toast.LENGTH_LONG).show()
            }
            COPY -> {
                val ip = AdbWifiMonitor.ip
                val port = AdbWifiMonitor.port
                if (ip != null && port != null) {
                    val cmd = "adb connect $ip:$port"
                    ctx.getSystemService(ClipboardManager::class.java)
                        .setPrimaryClip(ClipData.newPlainText("adb", cmd))
                    Toast.makeText(ctx, "已複製：$cmd", Toast.LENGTH_SHORT).show()
                }
            }
        }
    }
}

/** 開機後若有開啟常駐通知，自動重新啟動 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED && AdbWifi.isNotifyOn(ctx)) {
            StatusService.start(ctx)
        }
    }
}
