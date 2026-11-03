package tw.eddie.wireless_debug_toggle

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import java.net.Inet4Address

/** 讀寫開發者模式／無線偵錯的系統設定 */
object AdbWifi {
    const val KEY = "adb_wifi_enabled"
    const val DEV_KEY = Settings.Global.DEVELOPMENT_SETTINGS_ENABLED
    const val USB_KEY = Settings.Global.ADB_ENABLED
    private const val PREFS = "settings"
    private const val PREF_NOTIFY = "notify_enabled"

    fun isEnabled(ctx: Context): Boolean? = read(ctx, KEY)
    fun isDevEnabled(ctx: Context): Boolean? = read(ctx, DEV_KEY)
    fun isUsbEnabled(ctx: Context): Boolean? = read(ctx, USB_KEY)

    private fun read(ctx: Context, key: String): Boolean? = try {
        Settings.Global.getInt(ctx.contentResolver, key) == 1
    } catch (e: Exception) {
        null
    }

    fun canWrite(ctx: Context) =
        ctx.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) == PackageManager.PERMISSION_GRANTED

    /** 無線偵錯依附在開發者模式之下，開啟時一併打開開發者模式 */
    @Throws(SecurityException::class)
    fun setEnabled(ctx: Context, on: Boolean) {
        if (on) Settings.Global.putInt(ctx.contentResolver, DEV_KEY, 1)
        Settings.Global.putInt(ctx.contentResolver, KEY, if (on) 1 else 0)
    }

    /** USB 偵錯同樣依附在開發者模式之下 */
    @Throws(SecurityException::class)
    fun setUsbEnabled(ctx: Context, on: Boolean) {
        if (on) Settings.Global.putInt(ctx.contentResolver, DEV_KEY, 1)
        Settings.Global.putInt(ctx.contentResolver, USB_KEY, if (on) 1 else 0)
    }

    /** 關閉開發者模式時一併關閉無線偵錯 */
    @Throws(SecurityException::class)
    fun setDevEnabled(ctx: Context, on: Boolean) {
        if (!on) Settings.Global.putInt(ctx.contentResolver, KEY, 0)
        Settings.Global.putInt(ctx.contentResolver, DEV_KEY, if (on) 1 else 0)
    }

    fun isNotifyOn(ctx: Context) =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(PREF_NOTIFY, false)

    fun setNotifyOn(ctx: Context, on: Boolean) =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(PREF_NOTIFY, on).apply()
}

/**
 * 共用的即時狀態來源：Wi-Fi SSID / IP（NetworkCallback）、adbd 的 Port（mDNS）、
 * 以及兩個系統設定的變更（ContentObserver）。
 * 主畫面、快捷磚、常駐通知各自 acquire/release，最後一個釋放時才停止偵測。
 */
object AdbWifiMonitor {
    private const val SERVICE_TYPE = "_adb-tls-connect._tcp"

    private val main = Handler(Looper.getMainLooper())
    private lateinit var app: Context
    private var refs = 0
    private val listeners = LinkedHashSet<() -> Unit>()

    @Volatile var ssid: String? = null
        private set
    @Volatile var ip: String? = null
        private set

    private var netCallback: ConnectivityManager.NetworkCallback? = null
    private var observer: ContentObserver? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private var discovery: NsdManager.DiscoveryListener? = null

    // mDNS 掃到的 adb 服務：服務名稱 -> (IP, Port)
    private val services = HashMap<String, Pair<String, Int>>()
    private val resolveQueue = ArrayDeque<NsdServiceInfo>()
    private var resolving = false

    /** 只取本機 IP 的服務，避免顯示到同網段其他手機的 Port */
    val port: Int?
        get() {
            val myIp = ip ?: return null
            return synchronized(services) { services.values.firstOrNull { it.first == myIp }?.second }
        }

    fun acquire(ctx: Context, listener: () -> Unit) {
        main.post {
            app = ctx.applicationContext
            listeners += listener
            if (refs++ == 0) start()
            listener()
        }
    }

    fun release(listener: () -> Unit) {
        main.post {
            if (listeners.remove(listener) && --refs == 0) stop()
        }
    }

    /** 位置權限要在註冊時就具備，SSID 才不會被遮蔽，所以授權後重新註冊 */
    fun reregisterNetwork() = main.post {
        if (refs == 0) return@post
        unregisterNetwork()
        registerNetwork()
    }

    fun restartDiscovery() = main.post {
        if (refs == 0) return@post
        stopDiscovery()
        synchronized(services) { services.clear() }
        startDiscovery()
        notifyChanged()
    }

    private fun notifyChanged() = main.post { listeners.toList().forEach { it() } }

    private fun start() {
        registerNetwork()
        startDiscovery()
        val obs = object : ContentObserver(main) {
            override fun onChange(selfChange: Boolean) {
                notifyChanged()
            }
        }
        app.contentResolver.registerContentObserver(Settings.Global.getUriFor(AdbWifi.KEY), false, obs)
        app.contentResolver.registerContentObserver(Settings.Global.getUriFor(AdbWifi.DEV_KEY), false, obs)
        app.contentResolver.registerContentObserver(Settings.Global.getUriFor(AdbWifi.USB_KEY), false, obs)
        observer = obs
    }

    private fun stop() {
        observer?.let { app.contentResolver.unregisterContentObserver(it) }
        observer = null
        stopDiscovery()
        unregisterNetwork()
    }

    // ---------- Wi-Fi：SSID / IP ----------

    private fun registerNetwork() {
        if (netCallback != null) return
        val cm = app.getSystemService(ConnectivityManager::class.java)
        val cb = object : ConnectivityManager.NetworkCallback(FLAG_INCLUDE_LOCATION_INFO) {
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                val info = caps.transportInfo as? WifiInfo ?: return
                ssid = info.ssid?.trim('"')?.takeUnless { it.isBlank() || it == "<unknown ssid>" }
                notifyChanged()
            }

            override fun onLinkPropertiesChanged(network: Network, lp: LinkProperties) {
                ip = lp.linkAddresses.map { it.address }.firstOrNull { it is Inet4Address }?.hostAddress
                notifyChanged()
            }

            override fun onLost(network: Network) {
                ssid = null
                ip = null
                notifyChanged()
            }
        }
        val req = NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build()
        cm.registerNetworkCallback(req, cb)
        netCallback = cb
    }

    private fun unregisterNetwork() {
        val cm = app.getSystemService(ConnectivityManager::class.java)
        netCallback?.let { runCatching { cm.unregisterNetworkCallback(it) } }
        netCallback = null
    }

    // ---------- mDNS：找出 adbd 廣播的 Port ----------

    private fun startDiscovery() {
        if (discovery != null) return
        multicastLock = app.getSystemService(WifiManager::class.java)
            .createMulticastLock("adbwifi").apply { setReferenceCounted(false); acquire() }
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                main.post { discovery = null }
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}

            override fun onServiceFound(info: NsdServiceInfo) {
                synchronized(resolveQueue) { resolveQueue.addLast(info) }
                resolveNext()
            }

            override fun onServiceLost(info: NsdServiceInfo) {
                synchronized(services) { services.remove(info.serviceName) }
                notifyChanged()
            }
        }
        discovery = listener
        app.getSystemService(NsdManager::class.java)
            .discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    private fun stopDiscovery() {
        val nsd = app.getSystemService(NsdManager::class.java)
        discovery?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        discovery = null
        multicastLock?.release()
        multicastLock = null
    }

    // NsdManager 同一時間只能解析一個服務，所以排隊處理
    @Suppress("DEPRECATION")
    private fun resolveNext() {
        val next = synchronized(resolveQueue) {
            if (resolving) return
            resolveQueue.removeFirstOrNull()?.also { resolving = true }
        } ?: return
        app.getSystemService(NsdManager::class.java).resolveService(next, object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                done()
            }

            override fun onServiceResolved(info: NsdServiceInfo) {
                val host = if (Build.VERSION.SDK_INT >= 34) {
                    info.hostAddresses.firstOrNull { it is Inet4Address } ?: info.hostAddresses.firstOrNull()
                } else {
                    info.host
                }
                host?.hostAddress?.let { addr ->
                    synchronized(services) { services[info.serviceName] = addr to info.port }
                }
                notifyChanged()
                done()
            }

            private fun done() {
                synchronized(resolveQueue) { resolving = false }
                resolveNext()
            }
        })
    }
}
