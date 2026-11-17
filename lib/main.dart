import 'dart:async';

import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _ch = MethodChannel('tw.eddie/adbwifi');
const _grantCmd = 'adb shell pm grant tw.eddie.wireless_debug_toggle android.permission.WRITE_SECURE_SETTINGS';

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    const sub = FlexSubThemesData(
      cardRadius: 20,
      switchThumbSchemeColor: SchemeColor.onPrimary,
      snackBarBackgroundSchemeColor: SchemeColor.inverseSurface,
    );
    return MaterialApp(
      title: '無線偵錯',
      debugShowCheckedModeBanner: false,
      theme: FlexThemeData.light(scheme: FlexScheme.tealM3, subThemesData: sub),
      darkTheme: FlexThemeData.dark(scheme: FlexScheme.tealM3, subThemesData: sub, darkIsTrueBlack: false),
      themeMode: ThemeMode.system,
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  Map<Object?, Object?> _s = const {};
  Timer? _timer;
  bool _busy = false;
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))
    ..repeat();

  bool? get _enabled => _s['enabled'] as bool?;
  bool? get _devEnabled => _s['devEnabled'] as bool?;
  bool? get _usbEnabled => _s['usbEnabled'] as bool?;
  bool? get _wifiOn => _s['wifiOn'] as bool?;
  String? get _ssid => _s['ssid'] as String?;
  String? get _ip => _s['ip'] as String?;
  int? get _port => _s['port'] as int?;
  bool get _canWrite => _s['canWrite'] == true;
  bool get _hasLocation => _s['hasLocation'] == true;
  bool get _locationOn => _s['locationOn'] == true;
  bool get _notifyOn => _s['notifyOn'] == true;
  bool get _notifyAllowed => _s['notifyAllowed'] == true;
  String? get _version => _s['version'] as String?;
  int? get _updateProgress => _s['updateProgress'] as int?;

  // 雲端更新：有新版時為 {version, notes}
  Map<Object?, Object?>? _update;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
    // 第一次開啟時順便要位置權限（讀 SSID 用）
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _refresh();
      if (!_hasLocation) await _ch.invokeMethod('requestLocation');
      _checkUpdate(silent: true);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _start();
    } else if (state == AppLifecycleState.paused) {
      _timer?.cancel();
    }
  }

  void _start() {
    _timer?.cancel();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  Future<void> _refresh() async {
    final s = await _ch.invokeMethod<Map<Object?, Object?>>('getStatus');
    if (mounted && s != null) setState(() => _s = s);
  }

  Future<void> _set(String method, bool on) async {
    HapticFeedback.mediumImpact();
    setState(() => _busy = true);
    try {
      await _ch.invokeMethod(method, {'on': on});
    } on PlatformException catch (e) {
      _toast(e.code == 'NO_PERMISSION' ? '尚未授權，請先用電腦執行授權指令' : '失敗：${e.message}');
    } finally {
      await _refresh();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkUpdate({bool silent = false}) async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final r = await _ch.invokeMethod<Map<Object?, Object?>>('checkUpdate');
      if (!mounted) return;
      if (r != null && r['error'] != null) {
        if (!silent) _toast('檢查更新失敗：${r['error']}');
      } else {
        setState(() => _update = r);
        if (!silent && r == null) _toast('已是最新版本');
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _startUpdate() async {
    final r = await _ch.invokeMethod<String>('startUpdate');
    switch (r) {
      case 'need_permission':
        _toast('請允許「安裝未知應用程式」，返回後再按一次更新');
      case 'no_update':
        _toast('目前沒有可用的更新');
    }
    await _refresh();
  }

  void _copy(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    HapticFeedback.selectionClick();
    _toast('已複製$label');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  @override
  Widget build(BuildContext context) {
    final on = _enabled == true;
    return Scaffold(
      body: SafeArea(
        // 內容設計成一個畫面放得下；字體放大或小螢幕時仍可捲動
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          children: [
            _header(),
            if (_update != null) _updateCard(),
            if (_s.isNotEmpty && !_canWrite) _permissionCard(),
            const SizedBox(height: 12),
            _heroCard(on),
            const SizedBox(height: 12),
            _toggleGrid(),
            const SizedBox(height: 8),
            _footer(),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    final t = Theme.of(context).textTheme;
    return Row(
      children: [
        Expanded(
          child: Text('無線偵錯', style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
        ),
        IconButton.filledTonal(
          tooltip: '重新掃描 Port',
          icon: const Icon(Icons.refresh_rounded),
          onPressed: () {
            HapticFeedback.selectionClick();
            _ch.invokeMethod('restartScan');
          },
        ),
      ],
    );
  }

  /// 主卡片：左邊圓形開關，右邊狀態與連線資訊
  Widget _heroCard(bool on) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final addr = (on && _ip != null && _port != null) ? '$_ip:$_port' : null;
    final stateText = switch (_enabled) {
      true => '已開啟',
      false => '已關閉',
      null => '讀取中…',
    };
    final ipLine = _ip ?? (_wifiOn == false ? 'Wi-Fi 已關閉' : '未連線 Wi-Fi');
    final portLine = !on || _ip == null ? null : 'Port ${_port?.toString() ?? '搜尋中…'}';

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 16, 12),
        child: Row(
          children: [
            _powerButton(on),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 250),
                    style: t.headlineSmall!.copyWith(
                      fontWeight: FontWeight.w700,
                      color: on ? cs.primary : cs.onSurfaceVariant,
                    ),
                    child: Text(stateText),
                  ),
                  Text(_canWrite ? '點圓形按鈕切換' : '授權後即可切換', style: t.bodySmall),
                  const SizedBox(height: 10),
                  _miniInfo(Icons.wifi_rounded, _ssidText()),
                  const SizedBox(height: 4),
                  _miniInfo(Icons.lan_rounded, ipLine),
                  if (portLine != null) ...[const SizedBox(height: 4), _miniInfo(Icons.tag_rounded, portLine)],
                  if (addr != null) ...[
                    const SizedBox(height: 8),
                    FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      icon: const Icon(Icons.content_copy_rounded, size: 18),
                      label: const Text('複製連線指令'),
                      onPressed: () => _copy('adb connect $addr', '連線指令'),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniInfo(IconData icon, String text) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 18, color: cs.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }

  Widget _powerButton(bool on) {
    final cs = Theme.of(context).colorScheme;
    final enabled = _canWrite && !_busy && _enabled != null;
    const size = 112.0;

    return SizedBox(
      width: size * 1.3,
      height: size * 1.3,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 開啟時的擴散光圈
          if (on)
            AnimatedBuilder(
              animation: _pulse,
              builder: (_, _) {
                final v = Curves.easeOut.transform(_pulse.value);
                return Container(
                  width: size * (1 + 0.3 * v),
                  height: size * (1 + 0.3 * v),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: cs.primary.withValues(alpha: 0.35 * (1 - v)),
                  ),
                );
              },
            ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOutCubic,
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: on
                  ? LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [cs.primary, Color.lerp(cs.primary, Colors.black, 0.35)!],
                    )
                  : null,
              color: on ? null : cs.surfaceContainerHighest,
              boxShadow: [
                BoxShadow(
                  color: (on ? cs.primary : Colors.black).withValues(alpha: on ? 0.45 : 0.15),
                  blurRadius: on ? 24 : 10,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Material(
              type: MaterialType.transparency,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: enabled ? () => _set('setEnabled', !on) : null,
                child: Center(
                  child: _busy
                      ? SizedBox(
                          width: 36,
                          height: 36,
                          child: CircularProgressIndicator(strokeWidth: 3.5, color: on ? cs.onPrimary : cs.primary),
                        )
                      : Icon(
                          on ? Icons.wifi_tethering_rounded : Icons.wifi_tethering_off_rounded,
                          size: 52,
                          color: on ? cs.onPrimary : cs.onSurfaceVariant,
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Android 10 起 App 無法直接開關 Wi-Fi／切換網路，改叫出系統 Wi-Fi 面板
  void _openWifiPanel() {
    HapticFeedback.selectionClick();
    _ch.invokeMethod('openWifiPanel');
  }

  Future<void> _toggleNotify(bool v) async {
    HapticFeedback.selectionClick();
    await _ch.invokeMethod('setNotify', {'on': v});
    await _refresh();
  }

  String _onOff(bool? v) => switch (v) {
    true => '已開啟',
    false => '已關閉',
    null => '讀取中…',
  };

  /// 3×2 快捷方塊
  Widget _toggleGrid() {
    final writable = !_busy && _canWrite;
    final wifiOn = _wifiOn;
    final tiles = <Widget>[
      _Tile(
        icon: wifiOn == false ? Icons.wifi_off_rounded : Icons.wifi_rounded,
        title: 'Wi-Fi',
        subtitle: switch (wifiOn) {
          true => _ssid ?? '已開啟',
          false => '已關閉',
          null => '讀取中…',
        },
        hint: '點一下開關／切換網路',
        on: wifiOn == true,
        onTap: wifiOn == null ? null : _openWifiPanel,
      ),
      _Tile(
        icon: _enabled == true ? Icons.wifi_tethering_rounded : Icons.wifi_tethering_off_rounded,
        title: '無線偵錯',
        subtitle: _onOff(_enabled),
        on: _enabled == true,
        onTap: writable && _enabled != null ? () => _set('setEnabled', _enabled != true) : null,
      ),
      _Tile(
        icon: Icons.developer_mode_rounded,
        title: '開發者模式',
        subtitle: _onOff(_devEnabled),
        on: _devEnabled == true,
        onTap: writable && _devEnabled != null ? () => _set('setDevEnabled', _devEnabled != true) : null,
      ),
      _Tile(
        icon: Icons.usb_rounded,
        title: 'USB 偵錯',
        subtitle: _onOff(_usbEnabled),
        on: _usbEnabled == true,
        onTap: writable && _usbEnabled != null ? () => _set('setUsbEnabled', _usbEnabled != true) : null,
      ),
      _Tile(
        icon: Icons.notifications_active_rounded,
        title: '常駐通知',
        subtitle: _notifyOn && !_notifyAllowed ? '通知權限未開啟' : _onOff(_notifyOn),
        on: _notifyOn,
        onTap: () => _toggleNotify(!_notifyOn),
      ),
      _Tile(icon: Icons.dashboard_customize_rounded, title: '控制中心', subtitle: '加入快捷磚', on: false, onTap: _addTile),
    ];
    return Column(
      children: [
        for (var i = 0; i < tiles.length; i += 2) ...[
          if (i > 0) const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: tiles[i]),
              const SizedBox(width: 10),
              Expanded(child: tiles[i + 1]),
            ],
          ),
        ],
      ],
    );
  }

  Future<void> _addTile() async {
    final r = await _ch.invokeMethod<String>('addTile');
    _toast(switch (r) {
      'added' => '已加入控制中心',
      'already' => '已經在控制中心裡了',
      'declined' => '已取消',
      _ => '此系統不支援自動加入，請下拉控制中心 → 編輯，手動加入「無線偵錯」',
    });
  }

  Widget _footer() {
    final t = Theme.of(context).textTheme;
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('v${_version ?? '…'}', style: t.bodySmall),
        TextButton(onPressed: _checking ? null : () => _checkUpdate(), child: Text(_checking ? '檢查中…' : '檢查更新')),
      ],
    );
  }

  Widget _updateCard() {
    final cs = Theme.of(context).colorScheme;
    final progress = _updateProgress;
    final notes = (_update!['notes'] as String? ?? '').trim();
    return Card(
      color: cs.tertiaryContainer,
      margin: const EdgeInsets.only(top: 16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.system_update_rounded, color: cs.onTertiaryContainer),
                const SizedBox(width: 8),
                Text(
                  '有新版本 v${_update!['version']}',
                  style: TextStyle(color: cs.onTertiaryContainer, fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ],
            ),
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                notes,
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: cs.onTertiaryContainer),
              ),
            ],
            const SizedBox(height: 12),
            if (progress != null) ...[
              LinearProgressIndicator(value: progress / 100, borderRadius: BorderRadius.circular(4)),
              const SizedBox(height: 6),
              Text('下載中 $progress%', style: TextStyle(color: cs.onTertiaryContainer)),
            ] else
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('下載並更新'),
                  onPressed: _startUpdate,
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _ssidText() {
    if (_wifiOn == false) return 'Wi-Fi 已關閉';
    if (_ip == null) return '未連線 Wi-Fi';
    if (_ssid != null) return _ssid!;
    if (!_hasLocation) return '需要位置權限';
    if (!_locationOn) return '請開啟定位';
    return '讀取中…';
  }

  Widget _permissionCard() {
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: cs.errorContainer,
      margin: const EdgeInsets.only(top: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.lock_outline_rounded, color: cs.onErrorContainer),
                const SizedBox(width: 8),
                Text(
                  '尚未授權切換開關',
                  style: TextStyle(color: cs.onErrorContainer, fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('請在電腦上執行一次（需先開啟「USB 偵錯（安全設定）」）：', style: TextStyle(color: cs.onErrorContainer)),
            const SizedBox(height: 8),
            SelectableText(
              _grantCmd,
              style: TextStyle(color: cs.onErrorContainer, fontFamily: 'monospace', fontSize: 12),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.content_copy_rounded),
                label: const Text('複製指令'),
                onPressed: () => _copy(_grantCmd, '授權指令'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 快捷方塊：開啟時填滿主色容器，關閉時為灰底
class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.on,
    required this.onTap,
    this.hint,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String? hint;
  final bool on;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final fg = on ? cs.onPrimaryContainer : cs.onSurface;
    return Tooltip(
      message: hint ?? '',
      child: Material(
        color: on ? cs.primaryContainer : cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap == null
              ? null
              : () {
                  HapticFeedback.selectionClick();
                  onTap!();
                },
          child: Opacity(
            opacity: onTap == null ? 0.5 : 1,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 14, 10, 14),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: on ? cs.primary : cs.surfaceContainerHighest,
                    ),
                    child: Icon(icon, size: 22, color: on ? cs.onPrimary : cs.onSurfaceVariant),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700, color: fg),
                        ),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.bodySmall?.copyWith(color: fg.withValues(alpha: 0.8)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
