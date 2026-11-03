package tw.eddie.wireless_debug_toggle

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import org.json.JSONObject

data class UpdateInfo(
    val version: String,
    val apkUrl: String,
    val sha256Url: String,
    val notes: String,
)

/**
 * 雲端更新：查 GitHub 最新 Release → 下載 APK → 用 Release 附的 .sha256 驗證 → 交給系統安裝器。
 * 只接受本專案 Release 的下載網址；Android 一定會再跳出系統的安裝確認。
 */
object UpdateManager {
    private const val REPO = "wahaha232/WirelessDebugToggle"
    private const val LATEST_URL = "https://api.github.com/repos/$REPO/releases/latest"
    private const val DOWNLOAD_PREFIX = "https://github.com/$REPO/releases/download/"
    private const val APK_MAX_BYTES = 100L * 1024 * 1024
    private const val TIMEOUT_MS = 15_000

    fun currentVersion(ctx: Context): String =
        ctx.packageManager.getPackageInfo(ctx.packageName, 0).versionName ?: "0"

    /** 回傳比目前新的版本；已是最新回傳 null。要在背景執行緒呼叫。 */
    fun checkLatest(ctx: Context): UpdateInfo? {
        val json = JSONObject(readText(connect(LATEST_URL, "application/vnd.github+json").inputStream, 512 * 1024))
        val tag = json.getString("tag_name")
        if (!isNewer(currentVersion(ctx), tag)) return null
        val assets = json.getJSONArray("assets")
        var apk: String? = null
        var sha: String? = null
        for (i in 0 until assets.length()) {
            val asset = assets.getJSONObject(i)
            val name = asset.getString("name")
            val url = asset.getString("browser_download_url")
            if (!url.startsWith(DOWNLOAD_PREFIX)) continue
            if (name.endsWith(".apk")) apk = url
            if (name.endsWith(".apk.sha256")) sha = url
        }
        if (apk == null || sha == null) throw IOException("Release 缺少 APK 或 .sha256 檔")
        return UpdateInfo(tag.removePrefix("v"), apk, sha, json.optString("body"))
    }

    /** 下載並驗證，回傳 APK 檔。[onProgress] 為 0..100。要在背景執行緒呼叫。 */
    fun download(ctx: Context, info: UpdateInfo, onProgress: (Int) -> Unit): File {
        val expected = readText(connect(info.sha256Url, "*/*").inputStream, 4096)
            .trim().split(Regex("\\s+")).firstOrNull()?.lowercase()
            ?.takeIf { it.matches(Regex("[0-9a-f]{64}")) }
            ?: throw IOException("校驗檔格式錯誤")
        val dir = File(ctx.cacheDir, "updates").apply {
            deleteRecursively()
            mkdirs()
        }
        val target = File(dir, "update.apk")
        val digest = MessageDigest.getInstance("SHA-256")
        val conn = connect(info.apkUrl, "application/octet-stream")
        val total = conn.contentLengthLong
        if (total > APK_MAX_BYTES) throw IOException("APK 檔案過大")
        conn.inputStream.use { input ->
            target.outputStream().use { output ->
                val buffer = ByteArray(32 * 1024)
                var done = 0L
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    done += n
                    if (done > APK_MAX_BYTES) throw IOException("APK 檔案過大")
                    output.write(buffer, 0, n)
                    digest.update(buffer, 0, n)
                    if (total > 0) onProgress((done * 100 / total).toInt().coerceIn(0, 100))
                }
            }
        }
        val actual = digest.digest().joinToString("") { "%02x".format(it) }
        if (actual != expected) {
            target.delete()
            throw IOException("SHA-256 驗證失敗，已刪除下載檔")
        }
        return target
    }

    /** Android 8 以上，安裝 APK 前要使用者允許本 App「安裝未知應用程式」 */
    fun canInstall(ctx: Context) = ctx.packageManager.canRequestPackageInstalls()

    fun openInstallPermissionSettings(ctx: Context) {
        ctx.startActivity(
            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${ctx.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }

    fun install(ctx: Context, apk: File) {
        val uri = FileProvider.getUriForFile(ctx, "${ctx.packageName}.updates", apk)
        ctx.startActivity(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }

    /** 比較 "1.2.3" 與 "v1.2.4" 這類版本號 */
    fun isNewer(current: String, latest: String): Boolean {
        fun parts(v: String) = v.removePrefix("v").substringBefore('+').substringBefore('-')
            .split('.').map { it.toIntOrNull() ?: 0 }
        val a = parts(current)
        val b = parts(latest)
        for (i in 0 until maxOf(a.size, b.size)) {
            val x = a.getOrElse(i) { 0 }
            val y = b.getOrElse(i) { 0 }
            if (x != y) return y > x
        }
        return false
    }

    private fun readText(input: InputStream, max: Int): String = input.use {
        val out = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            val n = it.read(buffer)
            if (n < 0) break
            out.write(buffer, 0, n)
            if (out.size() > max) throw IOException("回應內容過大")
        }
        out.toString("UTF-8")
    }

    private fun connect(url: String, accept: String): HttpURLConnection {
        require(url.startsWith("https://"))
        val conn = URL(url).openConnection() as HttpURLConnection
        conn.connectTimeout = TIMEOUT_MS
        conn.readTimeout = TIMEOUT_MS
        conn.setRequestProperty("User-Agent", "WirelessDebugToggle")
        conn.setRequestProperty("Accept", accept)
        if (conn.responseCode !in 200..299) throw IOException("HTTP ${conn.responseCode}")
        return conn
    }
}
