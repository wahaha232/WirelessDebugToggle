# 無線偵錯開關（WirelessDebugToggle）

不用再進「設定 → 開發者選項」，從桌面、控制中心或通知列就能一鍵開關 Android 的**無線偵錯**和**開發者模式**，並且即時顯示電腦連線需要的 **IP:Port**。

## 功能

- **主畫面**：大型圓形開關，即時顯示 Wi-Fi 名稱（SSID）、IP、Port，一鍵複製 `adb connect IP:Port`
- **開發者模式開關**：開啟無線偵錯時會自動打開開發者模式；關閉開發者模式時，會一併關閉無線偵錯
- **控制中心快捷磚**：下拉控制中心點一下就能開關，長按開啟 App
- **雲端更新**：開啟 App 時自動檢查 GitHub 最新 Release，下載後以 SHA-256 驗證，再交給系統安裝器；也可以在畫面最下方手動「檢查更新」
- **常駐通知**：狀態列顯示圖示，通知內容是「SSID｜IP:Port」，附「開啟／關閉」和「複製連線指令」按鈕；開機後自動啟動

## 系統需求

- Android 11 以上（無線偵錯從 Android 11 開始提供）
- 一台裝有 adb 的電腦，只在第一次授權時需要

## 安裝與授權

1. 從 [Releases](../../releases) 下載 APK 並安裝。
2. 小米、POCO、Redmi 手機要先到開發者選項開啟 **「USB 偵錯（安全設定）」**。
3. 用 USB 或無線偵錯連上電腦，執行一次：

   ```bash
   adb shell pm grant tw.eddie.wireless_debug_toggle android.permission.WRITE_SECURE_SETTINGS
   ```

4. （選用）想讓 App 在背景時，通知裡也能顯示 SSID：

   ```bash
   adb shell pm grant tw.eddie.wireless_debug_toggle android.permission.ACCESS_BACKGROUND_LOCATION
   ```

授權只需要做一次，重開機後仍然有效。移除 App 後重新安裝，才需要再授權一次。

### 小米 / HyperOS 建議設定

- App 資訊 → **省電策略：無限制**、**自啟動：開啟**，避免常駐通知被系統關掉
- 要讀取 SSID，手機必須開啟定位

## 運作原理

| 項目 | 做法 |
|---|---|
| 開關 | 寫入 `Settings.Global` 的 `adb_wifi_enabled`、`development_settings_enabled`，需要 `WRITE_SECURE_SETTINGS` 權限 |
| Port | 有些機型（例如 HyperOS 3）沒有提供 `service.adb.tls.port`，所以 App 用 `NsdManager` 掃描 adbd 廣播的 mDNS 服務 `_adb-tls-connect._tcp`，再比對本機 IP 取得 Port |
| SSID / IP | `ConnectivityManager.NetworkCallback`（`FLAG_INCLUDE_LOCATION_INFO`） |
| 即時更新 | `ContentObserver` 監聽系統設定的變更；主畫面、快捷磚、通知三者共用 `AdbWifiMonitor` |

## 建置

```bash
flutter build apk --release --target-platform android-arm64
```

## 發佈新版（雲端更新來源）

1. 調高 `pubspec.yaml` 的 `version`，例如 `1.1.0+3` 改成 `1.2.0+4`（`+` 後面的數字也必須變大）
2. commit 後，在 Git Bash 執行：

   ```bash
   bash tools/release.sh "這次的更新內容"
   ```

腳本會建置 APK、產生 `.apk.sha256` 校驗檔、push，然後建立 GitHub Release。App 只接受本 repo Release 中附有 `.sha256` 的 APK。

APK 以這台電腦的 Android debug 金鑰簽章。換電腦建置時，必須用同一把金鑰，否則新版無法覆蓋安裝。

UI 主題使用 [flex_color_scheme](https://pub.dev/packages/flex_color_scheme)（MIT 授權）。

## 注意

關閉無線偵錯後，電腦的 adb 連線會中斷。重新開啟後 Port 會改變，但同一台電腦不需要重新配對，直接用新的 `adb connect IP:Port` 連線即可。
