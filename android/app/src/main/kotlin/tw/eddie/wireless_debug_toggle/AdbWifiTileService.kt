package tw.eddie.wireless_debug_toggle

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/** 控制中心快捷磚：點一下開關無線偵錯，副標顯示 IP:Port */
class AdbWifiTileService : TileService() {

    private val listener: () -> Unit = { updateTile() }

    override fun onStartListening() {
        super.onStartListening()
        AdbWifiMonitor.acquire(this, listener)
    }

    override fun onStopListening() {
        AdbWifiMonitor.release(listener)
        super.onStopListening()
    }

    override fun onClick() {
        super.onClick()
        if (!AdbWifi.canWrite(this)) {
            openApp()
            return
        }
        try {
            AdbWifi.setEnabled(this, AdbWifi.isEnabled(this) != true)
        } catch (e: SecurityException) {
            openApp()
        }
        updateTile()
    }

    private fun updateTile() {
        val tile = qsTile ?: return
        val on = AdbWifi.isEnabled(this) == true
        tile.state = if (on) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = "無線偵錯"
        tile.icon = Icon.createWithResource(this, if (on) R.drawable.ic_stat_on else R.drawable.ic_stat_off)
        tile.subtitle = when {
            !AdbWifi.canWrite(this) -> "尚未授權"
            !on -> "已關閉"
            else -> AdbWifiMonitor.port?.let { "${AdbWifiMonitor.ip}:$it" } ?: "搜尋 Port…"
        }
        tile.updateTile()
    }

    @SuppressLint("StartActivityAndCollapseDeprecated")
    private fun openApp() {
        val intent = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(
                PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE)
            )
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
