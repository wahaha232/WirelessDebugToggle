package tw.eddie.wireless_debug_toggle

import android.Manifest
import android.app.NotificationManager
import android.app.StatusBarManager
import android.content.ComponentName
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.location.LocationManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "tw.eddie/adbwifi"
        private const val REQ_LOCATION = 1
        private const val REQ_NOTIFY = 2
    }

    private val listener: () -> Unit = {}

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getStatus" -> result.success(status())
                    "setEnabled", "setDevEnabled" -> {
                        val on = call.argument<Boolean>("on") == true
                        try {
                            if (call.method == "setEnabled") AdbWifi.setEnabled(this, on)
                            else AdbWifi.setDevEnabled(this, on)
                            result.success(true)
                        } catch (e: SecurityException) {
                            result.error("NO_PERMISSION", e.message, null)
                        }
                    }
                    "setNotify" -> {
                        val on = call.argument<Boolean>("on") == true
                        AdbWifi.setNotifyOn(this, on)
                        if (on) {
                            if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIFY)
                            }
                            StatusService.start(this)
                        } else {
                            StatusService.stop(this)
                        }
                        result.success(null)
                    }
                    "addTile" -> requestAddTile(result)
                    "requestLocation" -> {
                        requestPermissions(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION), REQ_LOCATION)
                        result.success(null)
                    }
                    "restartScan" -> {
                        AdbWifiMonitor.restartDiscovery()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onResume() {
        super.onResume()
        AdbWifiMonitor.acquire(this, listener)
        // 服務可能被系統清掉，回到 App 時補啟動
        if (AdbWifi.isNotifyOn(this)) StatusService.start(this)
    }

    override fun onPause() {
        AdbWifiMonitor.release(listener)
        super.onPause()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_LOCATION) AdbWifiMonitor.reregisterNetwork()
    }

    private fun status(): Map<String, Any?> {
        val lm = getSystemService(LocationManager::class.java)
        val nm = getSystemService(NotificationManager::class.java)
        return mapOf(
            "enabled" to AdbWifi.isEnabled(this),
            "devEnabled" to AdbWifi.isDevEnabled(this),
            "ssid" to AdbWifiMonitor.ssid,
            "ip" to AdbWifiMonitor.ip,
            "port" to AdbWifiMonitor.port,
            "canWrite" to AdbWifi.canWrite(this),
            "hasLocation" to (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED),
            "locationOn" to lm.isLocationEnabled,
            "notifyOn" to AdbWifi.isNotifyOn(this),
            "notifyAllowed" to nm.areNotificationsEnabled(),
        )
    }

    /** Android 13+ 可直接跳出「加入控制中心」對話框 */
    private fun requestAddTile(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 33) {
            result.success("unsupported")
            return
        }
        val sbm = getSystemService(StatusBarManager::class.java)
        sbm.requestAddTileService(
            ComponentName(this, AdbWifiTileService::class.java),
            "無線偵錯",
            Icon.createWithResource(this, R.drawable.ic_stat_on),
            mainExecutor,
        ) { code ->
            result.success(
                when (code) {
                    StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED -> "added"
                    StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED -> "already"
                    StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_NOT_ADDED -> "declined"
                    else -> "error:$code"
                }
            )
        }
    }
}
